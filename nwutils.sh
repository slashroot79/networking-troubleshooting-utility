#!/bin/bash

# ==============================================================================
# Basic Network Diagnostics Script for Azure Linux Environments
# Author: Ragu Karuturi 
# This script provides multiple functions for network troubleshooting:
# 1. install: Installs a suite of networking tools based on the detected OS.
# 2. <target> [port]: Tests connectivity to a target FQDN or IP. Default ports 80 and 443.
# 3. run: Interactive mode to detect outbound connections and run diagnostics.
# ==============================================================================

SCRIPT_VERSION="1.3.0"

# Default log dir - applicable for Azure Linux App Services
LOG_DIR="/home/Logfiles"

# Create a custom log dir (/Appuserlogs) in IaaS or non App Service hosts. Imp: Enable storage in Custom Containers (App Service). 
if [ ! -d "$LOG_DIR" ] || [ ! -w "$LOG_DIR" ]; then
    LOG_DIR="/Appuserlogs"
    mkdir -p "$LOG_DIR" || { echo "Failed to create log directory $LOG_DIR"; exit 1; }
fi

# Create Log files
LOG_FILE="$LOG_DIR/nwutils.log"
PACKET_CAPTURE_FILE="$LOG_DIR/nwutils_$(date +%s).pcap"

# Test access
touch "$LOG_FILE" || {
    echo "Cannot write to log file"
    exit 1
}

# Log messages to both stdout and log file
log_message() {
    message="$1"
    timestamped_message="[$(date +'%Y-%m-%d %H:%M:%S')] $message"
    echo -e "$timestamped_message" | tee -a "$LOG_FILE"
}

log_message "**********************************************************"
log_message "Network Diagnostics Script Version: $SCRIPT_VERSION"
log_message "Log file initialized at $LOG_FILE"
log_message "Logging all diagnostics to $LOG_FILE"
log_message "**********************************************************"

# Check if the script is run as root else attempt to run with sudo
root_or_try() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        log_message "Not running as root. Attempting to re-run with sudo..."
        sudo "$0" "$@" || {
            log_message "sudo attempt failed or was canceled by user."
            exit 1
        }
        exit 0
    else
        log_message "Error: sudo not available and script is not running as root."
        exit 1
    fi
}

# Port validation helper function
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Host validation helper function
validate_host() {
    local host="$1"
    # IPv4
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    # FQDN 
    if [[ "$host" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# INSTALLATION
# Detects OS and installs networking tools
install_tools() {
    root_or_try install
    log_message "*** Beginning installation of tools ***"
    log_message "**********************************************************"

    # Detect OS
    local OS_ID=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        log_message "Error: Cannot detect operating system. /etc/os-release not found."
        exit 1
    fi

    log_message "Operating System Detected: -- $OS_ID"

    local PKG_MANAGER=""
    local INSTALL_CMD=""
    local UPDATE_CMD=""
    local packages_to_install=""

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            UPDATE_CMD="apt-get update"
            INSTALL_CMD="apt-get install -y"
            packages_to_install="nmap bc netcat-openbsd tcpdump dnsutils iproute2 iftop net-tools iptraf-ng nethogs nload curl wget lsof tshark"
            ;;
        rhel|mariner|azurelinux) # Red Hat, CBL-Mariner, Azure Linux
            PKG_MANAGER="dnf"
            if ! command -v dnf &> /dev/null; then
                PKG_MANAGER="yum"
            fi
            UPDATE_CMD="$PKG_MANAGER makecache"
            INSTALL_CMD="$PKG_MANAGER install -y"
            # nmap-ncat provides 'nc', bind-utils provides 'nslookup'.
            # NOTE: iftop, iptraf-ng, nethogs are not in standard Mariner/Azure Linux repos — omitted.
            # tshark is handled separately below: try 'tshark' package first, fall back to 'wireshark'
            # (the wireshark package bundles the tshark binary on Mariner/Azure Linux).
            packages_to_install="nmap bc nmap-ncat tcpdump iproute bind-utils net-tools curl wget lsof"
            ;;
        alpine)
            PKG_MANAGER="apk"
            UPDATE_CMD="apk update"
            INSTALL_CMD="apk add"
            packages_to_install="nmap bc nmap-ncat tcpdump iproute2 bind-tools iftop net-tools iptraf-ng nethogs nload curl wget lsof tshark"
            ;;
        *)
            log_message "Unsupported Operating System: $OS_ID. Cannot install tools."
            exit 1
            ;;
    esac

    log_message "Updating package lists using $PKG_MANAGER..."
    $UPDATE_CMD >/dev/null 2>&1

    log_message "Starting installation of tools..."
    for pkg in $packages_to_install; do
        if $INSTALL_CMD $pkg >/dev/null 2>&1; then
            log_message "Successfully installed $pkg."
        else
            log_message "Skip install for $pkg: Package not found or failed to install."
        fi
    done

    # tshark special handling:
    # On Mariner/Azure Linux the standalone 'tshark' package may not exist;
    # the 'wireshark' package ships the tshark binary instead.
    # On other distros 'tshark' is the correct package name — try it first.
    if ! command -v tshark &>/dev/null; then
        log_message "tshark not found after install attempt — trying 'tshark' package..."
        if $INSTALL_CMD tshark >/dev/null 2>&1 && command -v tshark &>/dev/null; then
            log_message "Successfully installed tshark."
        else
            log_message "'tshark' package not available — trying 'wireshark' as fallback..."
            if $INSTALL_CMD wireshark >/dev/null 2>&1 && command -v tshark &>/dev/null; then
                log_message "Successfully installed tshark via wireshark package."
            else
                log_message "WARNING: tshark could not be installed. Packet analysis (step 5b/5c) will be skipped."
            fi
        fi
    else
        log_message "tshark is already available."
    fi

    log_message "*** Installation Complete ***"
    log_message "**********************************************************"
}

# Checks if required tools are present and prompts for install if not.
# Usage: check_tools "tool1" "tool2" ...
check_tools() {
    local missing_tools=()
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_message "Required troubleshooting tools are missing..."
        read -p "Would you like to run the tool installation now? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            install_tools
        else
            log_message "Installation skipped. Cannot proceed without required tools."
            exit 1
        fi
    else
        log_message "Troubleshooting tools found...skipping installation..."
    fi
}

dns_lookup() {
    local target_ip="$1"
    if [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_message "  [dns] Reverse lookup (IP → name)"

        if out=$(dig +short -x "$target_ip" 2>/dev/null); then
            if [ -n "$out" ]; then
                echo "$out" | sed 's/^/  [dns] /' | tee -a "$LOG_FILE"
                return
            fi
        fi

        if out=$(nslookup "$target_ip" 2>/dev/null); then
            echo "$out" | sed 's/^/  [dns] /' | tee -a "$LOG_FILE"
        else
            log_message "  [dns] No PTR record found (normal for many IPs)"
        fi

    else
        log_message "  [dns] Forward lookup (name → IP)"

        if out=$(dig +short "$target_ip" 2>/dev/null); then
            if [ -n "$out" ]; then
                echo "$out" | sed 's/^/  [dns] /' | tee -a "$LOG_FILE"
                return
            fi
        fi

        if out=$(nslookup "$target_ip" 2>/dev/null); then
            echo "$out" | sed 's/^/  [dns] /' | tee -a "$LOG_FILE"
        else
            log_message "  [dns] Forward lookup failed"
        fi
    fi
}

run_nping() {
    local target_ip="$1"
    local target_port="$2"
    if ! command -v nping >/dev/null 2>&1; then
        log_message "  [nping] not installed on this system"
        return
    fi
    # Execute nping and process everything in a single awk stream
    nping --tcp-connect -p "$target_port" -c 5 "$target_ip" 2>&1 | awk '
    /SENT|RCVD/ { print "  [nping] " $0 }
    /Max rtt:/ { print "  [nping] Stats: " $0 }
    
    # Improved parsing: look specifically for the integers in the summary line
    /TCP connection attempts:/ {
        # Extract numbers using match or field position
        # "TCP connection attempts: 5 | Successful connections: 5 | Failed: 0 (0.00%)"
        split($0, parts, "|");
        
        # Parse Successful count from the second part
        split(parts[2], success_part, ":");
        success = success_part[2] + 0;
        
        # Parse Failed count from the third part
        split(parts[3], fail_part, ":");
        fail = fail_part[2] + 0;
        
        total = success + fail;

        print "  [nping] Summary: " $0
        
        if (success > 0) {
            printf "  [nping] Result: SUCCESS (%d/%d connections worked)\n", success, total
        } else {
            printf "  [nping] Result: FAILED (All %d attempts failed)\n", total
        }
    }' | tee -a "$LOG_FILE"
    log_message "[nping] Test complete."
}

# Network diagnostics helper function
# Usage: run_diagnostics <target_ip_or_fqdn> <port>
run_diagnostics() {
    local target_ip="$1"
    local target_port="$2"

    # Generate a unique pcap file per run so multiple-port calls don't clobber each other
    local safe_target="${target_ip//[^a-zA-Z0-9]/_}"
    local pcap_file="$LOG_DIR/nwutils_${safe_target}_${target_port}_$(date +%s).pcap"

    log_message "=========================================================="
    log_message "Starting diagnostics: $target_ip  port $target_port"
    log_message "=========================================================="

    # --- [1/5] DNS resolution ---
    log_message ""
    log_message "[1/5] DNS Lookup"
    dns_lookup "$target_ip"
    log_message "----------------------------------------------------------"

    # --- [2/5] TCP Reachability: nc ---
    log_message ""
    log_message "[2/5] TCP Reachability test (nc)"
    local nc_output
    local nc_rc
    nc_output=$(nc -zv -w 3 "$target_ip" "$target_port" 2>&1)
    nc_rc=$?
    if [ $nc_rc -eq 0 ]; then
        log_message "  [nc] SUCCESS: $target_ip:$target_port is reachable."
        echo "  [nc] Detailed output: $nc_output" >> "$LOG_FILE" # logged to file only
    else
        log_message "  [nc] FAILED: $target_ip:$target_port is NOT reachable."
        log_message "  [nc] Details: $nc_output"
        log_message "  [nc] Action: Check NSGs/Firewalls, validate IP/Port, or review the packet capture below."
    fi
    log_message "----------------------------------------------------------"

    # --- [3/5] HTTP/HTTPS response check (curl) — web ports only ---
    log_message ""
    if [[ "$target_port" == "80" || "$target_port" == "443" || "$target_port" == "8080" || "$target_port" == "8443" ]]; then
        log_message "[3/5] HTTP response check (curl)"
        local scheme="http"
        [[ "$target_port" == "443" || "$target_port" == "8443" ]] && scheme="https"
        local curl_out
        curl_out=$(curl -sk --max-time 5 -o /dev/null \
            -w "HTTP %{http_code} | Connect: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s" \
            "${scheme}://${target_ip}:${target_port}/" 2>&1)
        log_message "  [curl] $curl_out"
    else
        log_message "[3/5] HTTP check skipped (port $target_port is not a standard web port)"
    fi
    log_message "----------------------------------------------------------"

    # --- [4/5] TCP Connectivity & latency: nping ---
    log_message ""
    log_message "[4/5] TCP Connectivity & latency test (nping)"
    run_nping "$target_ip" "$target_port"
    log_message "----------------------------------------------------------"

    # --- [5/5] Packet capture (60s) filtered to target traffic + DNS ---
    log_message ""
    log_message "[5/5] Packet capture (60s) — capturing traffic to $target_ip:$target_port and DNS..."

    # Apply the BPF filter at capture time: reduces disk usage and I/O noise
    local -a tcpdump_args=(-i any -tttt -nn -U -w "$pcap_file"
        "(host $target_ip and port $target_port) or port 53")

    if [ "$EUID" -ne 0 ]; then
        log_message "  Using sudo for tcpdump..."
        sudo timeout 60 tcpdump "${tcpdump_args[@]}" >/dev/null 2>&1
    else
        timeout 60 tcpdump "${tcpdump_args[@]}" >/dev/null 2>&1
    fi
    log_message "  Packet capture saved to: $pcap_file"
    log_message "----------------------------------------------------------"

    # --- Pre-analysis checks ---
    log_message ""
    if [ ! -s "$pcap_file" ]; then
        log_message "  Warning: Pcap file is empty — capture failed or no matching packets found."
        log_message "  Hint: Ensure traffic to $target_ip:$target_port occurred during the 60s capture window."
        return
    fi
    if ! command -v tshark &>/dev/null; then
        log_message "  [tshark] Not installed — skipping packet analysis. Pcap saved for manual review."
        return
    fi

    # Temp file used to pass numeric stats from awk subshells back to bash for the health report
    local stats_file
    stats_file=$(mktemp)
    # Seed the nc reachability result (set earlier in this function)
    printf "nc_rc=%d\n" "$nc_rc" > "$stats_file"

    # -----------------------------------------------------------------------
    # [5b/6] DNS Analysis
    # Parses DNS queries and responses from the pcap.
    # Flags: NXDOMAIN, ServFail, other RCODE errors, slow responses (>1s)
    # -----------------------------------------------------------------------
    log_message ""
    log_message "[5b/6] DNS Analysis"
    log_message "  Type=QUERY/RESP  |  RCode: 0=OK  2=ServFail  3=NXDOMAIN  |  RespTime in seconds"
    echo "" | tee -a "$LOG_FILE"

    tshark -r "$pcap_file" \
        -Y "dns" \
        -T fields \
        -e frame.time_relative \
        -e dns.flags.response \
        -e dns.qry.name \
        -e dns.qry.type \
        -e dns.flags.rcode \
        -e dns.time \
        -E header=n -E separator=/t -E quote=d 2>/dev/null | \
    awk -F'\t' -v sf="$stats_file" '
    BEGIN {
        fmt = "%-9s | %-5s | %-50s | %-6s | %-7s | %-10s\n";
        sep = "------------------------------------------------------------------------------------------------------------------------------------";
        print sep;
        printf fmt, "Time(s)", "Type", "Name / Annotation", "QType", "RCode", "RespTime(s)";
        print sep;
        dns_q=0; dns_nxdomain=0; dns_servfail=0; dns_slow=0; dns_other_err=0;
    }
    {
        gsub(/"/, "", $0);
        time     = ($1 != "" ? sprintf("%.4f", $1) : "-");
        is_resp  = $2;
        name     = ($3 != "" ? $3 : "-");
        qtype    = ($4 != "" ? $4 : "-");
        rcode    = $5;
        resptime = ($6 != "" ? sprintf("%.4f", $6+0) : "-");
        ptype    = (is_resp == "1" ? "RESP" : "QUERY");

        if (is_resp == "0") dns_q++;

        note = "";
        if      (rcode == "3")                                    { note = " !! NXDOMAIN";        dns_nxdomain++;   }
        else if (rcode == "2")                                    { note = " !! SERVFAIL";         dns_servfail++;   }
        else if (rcode != "" && rcode != "0" && rcode ~ /[0-9]/) { note = " !! ERR(rcode="rcode")"; dns_other_err++; }

        if ($6 != "" && $6+0 > 1.0) { note = note " [SLOW>1s]"; dns_slow++; }

        printf fmt, time, ptype, name note, qtype, (rcode != "" ? rcode : "-"), resptime;
    }
    END {
        print sep;
        printf "\n  DNS: %d queries | %d NXDOMAIN | %d ServFail | %d other errors | %d slow(>1s)\n",
               dns_q, dns_nxdomain, dns_servfail, dns_other_err, dns_slow;
        # Write stats for health report (append so nc_rc seed is preserved)
        printf "dns_queries=%d\n",   dns_q          >> sf;
        printf "dns_nxdomain=%d\n",  dns_nxdomain   >> sf;
        printf "dns_servfail=%d\n",  dns_servfail   >> sf;
        printf "dns_slow=%d\n",      dns_slow        >> sf;
        printf "dns_other_err=%d\n", dns_other_err   >> sf;
    }' | tee -a "$LOG_FILE"
    log_message "----------------------------------------------------------"

    # -----------------------------------------------------------------------
    # [5c/6] TCP Stream Table
    # Per-packet breakdown with flags, RTT, retransmissions, zero-window,
    # lost segments, and duplicate ACKs.
    # Columns: Time | IFace | Src:Port -> Dst:Port | Flags | RTT | Bytes | Delta | Ret | ZW | DA
    # -----------------------------------------------------------------------
    log_message ""
    log_message "[5c/6] TCP Stream Table — $target_ip:$target_port"
    log_message "  Flags: [S]=SYN [A]=ACK [P]=PSH [F]=FIN [R]=RST"
    log_message "  *=Retransmission  ZW=Zero-Window  LS=LostSegment  DA=DupACK"
    echo "" | tee -a "$LOG_FILE"

    tshark -r "$pcap_file" \
        -Y "tcp.port == $target_port && ip.addr == $target_ip" \
        -T fields \
        -e tcp.stream \
        -e frame.time_relative \
        -e frame.interface_name \
        -e ip.src -e tcp.srcport \
        -e ip.dst -e tcp.dstport \
        -e tcp.flags.str \
        -e tcp.seq -e tcp.ack \
        -e tcp.len \
        -e tcp.analysis.ack_rtt \
        -e tcp.analysis.retransmission \
        -e frame.time_delta \
        -e tcp.analysis.zero_window \
        -e tcp.analysis.lost_segment \
        -e tcp.analysis.duplicate_ack \
        -e tcp.window_size_value \
        -E header=n -E separator=/t -E quote=d 2>/dev/null | \
    awk -F'\t' -v sf="$stats_file" '
    BEGIN {
        fmt  = "%-12s | %-8s | %-44s | %-6s | %-9s | %-6s | %-9s | %-3s | %-3s | %-3s | %-3s\n";
        sep  = "---------------------------------------------------------------------------------------------------------------------------------------";
        ssep = "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -";
        print sep;
        printf fmt, "Time(s)", "IFace", "Source:Port -> Dest:Port", "Flags", "RTT(ms)", "Bytes", "Delta(s)", "Ret", "ZW", "LS", "DA";
        print sep;
        cur_stream = -1;
        total=0; retrans=0; rst=0; fin=0; syn=0; synack=0;
        zw=0; ls=0; da=0; rtt_sum=0; rtt_n=0; rtt_max=0;
    }
    {
        gsub(/"/, "", $0);
        stream=$1; time=sprintf("%.4f",$2); iface=($3!=""?$3:"any");
        src=$4; sport=$5; dst=$6; dport=$7;
        flags=$8; seq=$9; ack=$10; len=$11;
        rtt=$12; retransmit=$13; delta=sprintf("%.4f",$14);
        f_zw=$15; f_ls=$16; f_da=$17; winsize=$18;

        # New stream separator
        if (stream != cur_stream) {
            if (cur_stream != -1) print ssep;
            printf "  [ TCP STREAM %s ]\n", stream;
            cur_stream = stream;
        }

        direction = src ":" sport " -> " dst ":" dport;

        # Compact flags: "....S.A." -> "[SA]"
        pf = "[";
        if (flags ~ /S/) pf = pf "S";
        if (flags ~ /A/) pf = pf "A";
        if (flags ~ /P/) pf = pf "P";
        if (flags ~ /R/) pf = pf "R";
        if (flags ~ /F/) pf = pf "F";
        pf = pf "]";
        if (pf == "[]") pf = "[.]";

        # RTT: seconds -> milliseconds
        rtt_val = "-";
        if (rtt != "") {
            rtt_ms = rtt * 1000;
            rtt_val = sprintf("%.2f", rtt_ms);
            rtt_sum += rtt_ms; rtt_n++;
            if (rtt_ms > rtt_max) rtt_max = rtt_ms;
        }

        # Anomaly flags
        r_f = ""; zw_f = ""; ls_f = ""; da_f = "";
        if (retransmit != "") { r_f  = "*";  retrans++; time = time "*"; }
        if (f_zw != "")       { zw_f = "!";  zw++; }
        if (f_ls != "")       { ls_f = "!";  ls++; }
        if (f_da != "")       { da_f = ".";  da++; }

        if (flags ~ /R/) rst++;
        if (flags ~ /F/) fin++;
        if (flags ~ /S/ && flags !~ /A/) syn++;
        if (flags ~ /S/ && flags ~ /A/)  synack++;
        total++;

        printf fmt, time, iface, direction, pf, rtt_val, len, delta, r_f, zw_f, ls_f, da_f;
    }
    END {
        print sep;
        avg_rtt = (rtt_n > 0 ? rtt_sum / rtt_n : 0);
        printf "\n  TCP: %d pkts | %d retrans(*) | %d RST | %d FIN | %d ZeroWin(!) | %d LostSeg(!) | %d DupACK(.)\n",
               total, retrans, rst, fin, zw, ls, da;
        printf "  RTT: %.2f ms avg | %.2f ms max | %d samples\n", avg_rtt, rtt_max, rtt_n;
        if (syn > 0 && synack == 0)
            printf "  NOTE: %d SYN(s) sent, 0 SYN-ACK(s) received — port may be FILTERED or host UNREACHABLE\n", syn;

        # Append TCP stats for health report
        printf "tcp_total=%d\n",    total   >> sf;
        printf "tcp_retrans=%d\n",  retrans >> sf;
        printf "tcp_rst=%d\n",      rst     >> sf;
        printf "tcp_fin=%d\n",      fin     >> sf;
        printf "tcp_zw=%d\n",       zw      >> sf;
        printf "tcp_ls=%d\n",       ls      >> sf;
        printf "tcp_da=%d\n",       da      >> sf;
        printf "tcp_syn=%d\n",      syn     >> sf;
        printf "tcp_synack=%d\n",   synack  >> sf;
        printf "tcp_avg_rtt=%.2f\n", avg_rtt  >> sf;
        printf "tcp_max_rtt=%.2f\n", rtt_max  >> sf;
    }' | tee -a "$LOG_FILE"
    log_message "----------------------------------------------------------"

    # -----------------------------------------------------------------------
    # [5d/6] Health Report
    # Sources the stats file (populated by the two awk passes above) and
    # prints a structured assessment for each diagnostic category.
    # -----------------------------------------------------------------------
    # shellcheck disable=SC1090
    [ -s "$stats_file" ] && source "$stats_file"
    rm -f "$stats_file"

    # ── DNS ─────────────────────────────────────────────────────────────────
    local dns_status
    if   [ "${dns_nxdomain:-0}" -gt 0 ] || [ "${dns_servfail:-0}" -gt 0 ] || [ "${dns_other_err:-0}" -gt 0 ]; then
        dns_status="FAIL     | NXDOMAIN:${dns_nxdomain:-0}  ServFail:${dns_servfail:-0}  OtherErr:${dns_other_err:-0}"
    elif [ "${dns_slow:-0}" -gt 0 ]; then
        dns_status="WARNING  | ${dns_slow} response(s) >1s — slow DNS can cause connection timeouts"
    elif [ "${dns_queries:-0}" -eq 0 ]; then
        dns_status="N/A      | No DNS queries found in capture"
    else
        dns_status="OK       | ${dns_queries:-0} queries, all resolved without errors"
    fi

    # ── Reachability ────────────────────────────────────────────────────────
    local reach_status
    if [ "${nc_rc:-1}" -eq 0 ]; then
        reach_status="OK       | TCP connect succeeded (nc)"
    elif [ "${tcp_syn:-0}" -gt 0 ] && [ "${tcp_synack:-0}" -eq 0 ]; then
        reach_status="FAIL     | ${tcp_syn} SYN(s) sent, no SYN-ACK received — port filtered or host unreachable"
    elif [ "${tcp_synack:-0}" -gt 0 ]; then
        reach_status="PARTIAL  | nc failed but SYN-ACK(s) observed — likely transient or timing issue"
    else
        reach_status="FAIL     | TCP connection refused or no packets exchanged"
    fi

    # ── Latency ─────────────────────────────────────────────────────────────
    local latency_status
    local avg_int max_int
    avg_int=$(awk -v v="${tcp_avg_rtt:-0}" 'BEGIN{printf "%d", int(v)}')
    max_int=$(awk -v v="${tcp_max_rtt:-0}" 'BEGIN{printf "%d", int(v)}')
    if   [ "${avg_int}" -ge 200 ]; then
        latency_status="HIGH     | avg ${tcp_avg_rtt}ms  max ${tcp_max_rtt}ms (threshold: 200ms)"
    elif [ "${avg_int}" -ge 100 ]; then
        latency_status="ELEVATED | avg ${tcp_avg_rtt}ms  max ${tcp_max_rtt}ms (threshold: 100ms)"
    elif [ "${avg_int}" -eq 0 ] && [ "${tcp_total:-0}" -eq 0 ]; then
        latency_status="N/A      | No TCP packets captured"
    else
        latency_status="OK       | avg ${tcp_avg_rtt}ms  max ${tcp_max_rtt}ms"
    fi

    # ── Timeouts ────────────────────────────────────────────────────────────
    local timeout_status
    if [ "${tcp_syn:-0}" -gt 0 ] && [ "${tcp_synack:-0}" -eq 0 ] && [ "${tcp_retrans:-0}" -gt 0 ]; then
        timeout_status="SUSPECTED| SYN retransmitted with no SYN-ACK — handshake timed out"
    elif [ "${tcp_zw:-0}" -gt 0 ]; then
        timeout_status="RISK     | ${tcp_zw} zero-window condition(s) — receiver buffer full, sender stalled"
    else
        timeout_status="OK       | No timeout indicators detected"
    fi

    # ── Packet Drops ────────────────────────────────────────────────────────
    local drops_status
    local drop_total=$(( ${tcp_retrans:-0} + ${tcp_ls:-0} + ${tcp_da:-0} ))
    if [ "$drop_total" -gt 0 ]; then
        drops_status="DETECTED | retrans:${tcp_retrans:-0}  lost_seg:${tcp_ls:-0}  dup_ack:${tcp_da:-0}"
    else
        drops_status="OK       | No retransmissions, lost segments, or duplicate ACKs"
    fi

    # ── Connection Resets / Closes ───────────────────────────────────────────
    local reset_status
    if [ "${tcp_rst:-0}" -gt 0 ] && [ "${tcp_fin:-0}" -gt 0 ]; then
        reset_status="DETECTED | ${tcp_rst} RST (forced close) + ${tcp_fin} FIN (graceful close)"
    elif [ "${tcp_rst:-0}" -gt 0 ]; then
        reset_status="DETECTED | ${tcp_rst} RST packet(s) — connection(s) forcibly closed (firewall/app reject)"
    elif [ "${tcp_fin:-0}" -gt 0 ]; then
        reset_status="INFO     | ${tcp_fin} FIN packet(s) — graceful connection close observed"
    else
        reset_status="OK       | No RST or unexpected FIN packets"
    fi

    # ── Overall ─────────────────────────────────────────────────────────────
    local overall
    if   [[ "$dns_status"     == FAIL*     ]] || \
         [[ "$reach_status"   == FAIL*     ]] || \
         [[ "$timeout_status" == SUSPECTED* ]]; then
        overall="!!! FAIL"
    elif [[ "$drops_status"   == DETECTED* ]] || \
         [[ "$reset_status"   == DETECTED* ]] || \
         [[ "$latency_status" == HIGH*     ]]; then
        overall="!! DEGRADED"
    elif [[ "$dns_status"     == WARNING*  ]] || \
         [[ "$latency_status" == ELEVATED* ]] || \
         [[ "$reach_status"   == PARTIAL*  ]] || \
         [[ "$timeout_status" == RISK*     ]]; then
        overall="!  WARNING"
    else
        overall="   HEALTHY"
    fi

    # ── Print report (screen + log) ──────────────────────────────────────────
    log_message ""
    log_message "[5d/6] Health Report"
    {
        echo "  +------------------+------------------------------------------------------------------------------+"
        printf "  | %-16s | %-78s |\n" "Target"          "$target_ip : $target_port"
        echo "  +------------------+------------------------------------------------------------------------------+"
        printf "  | %-16s | %-78s |\n" "DNS"             "$dns_status"
        printf "  | %-16s | %-78s |\n" "Reachability"    "$reach_status"
        printf "  | %-16s | %-78s |\n" "Latency"         "$latency_status"
        printf "  | %-16s | %-78s |\n" "Timeouts"        "$timeout_status"
        printf "  | %-16s | %-78s |\n" "Packet Drops"    "$drops_status"
        printf "  | %-16s | %-78s |\n" "Conn Reset/Close" "$reset_status"
        echo "  +------------------+------------------------------------------------------------------------------+"
        printf "  | %-16s | %-78s |\n" "OVERALL STATUS"  "$overall"
        echo "  +------------------+------------------------------------------------------------------------------+"
    } | tee -a "$LOG_FILE"

    log_message "----------------------------------------------------------"

    # ── [6/6] Natural Language Summary ──────────────────────────────────────
    # Builds a readable, plain-English narrative from the collected stats.
    # Each sentence is only emitted when there is something specific to say.
    log_message ""
    log_message "[6/6] Summary"
    {
        echo ""
        echo "  Target: $target_ip on port $target_port"
        echo ""

        # ── Opening line ─────────────────────────────────────────────────────
        if [[ "$overall" == *FAIL* ]]; then
            echo "  Connectivity to $target_ip:$target_port is FAILING. One or more critical issues were detected."
        elif [[ "$overall" == *DEGRADED* ]]; then
            echo "  Connectivity to $target_ip:$target_port is DEGRADED. The connection is reachable but experiencing problems."
        elif [[ "$overall" == *WARNING* ]]; then
            echo "  Connectivity to $target_ip:$target_port is reachable but shows early warning signs."
        else
            echo "  Connectivity to $target_ip:$target_port looks HEALTHY. No significant issues were detected."
        fi
        echo ""

        # ── DNS ──────────────────────────────────────────────────────────────
        if [ "${dns_queries:-0}" -eq 0 ]; then
            echo "  DNS: No DNS queries were seen in the capture. This could mean the target was resolved"
            echo "       from cache before the capture started, or DNS traffic was not present."
        elif [ "${dns_nxdomain:-0}" -gt 0 ]; then
            echo "  DNS: The hostname could not be resolved — ${dns_nxdomain} NXDOMAIN response(s) were received."
            echo "       This means the DNS server has no record for this name. Check for typos in the"
            echo "       hostname, or verify the DNS zone has the correct entry."
        elif [ "${dns_servfail:-0}" -gt 0 ]; then
            echo "  DNS: The DNS server returned ${dns_servfail} SERVFAIL response(s). This indicates the DNS"
            echo "       server itself has an internal problem resolving the query (e.g. misconfigured"
            echo "       forwarder, unreachable upstream resolver, or DNSSEC failure)."
        elif [ "${dns_other_err:-0}" -gt 0 ]; then
            echo "  DNS: ${dns_other_err} DNS error(s) with unexpected response codes were detected."
            echo "       Review the DNS Analysis table above for the specific rcode values."
        elif [ "${dns_slow:-0}" -gt 0 ]; then
            echo "  DNS: Resolution succeeded, but ${dns_slow} response(s) took over 1 second."
            echo "       Slow DNS adds latency before every new connection and can cause application"
            echo "       timeouts if the app treats DNS delay as a connection timeout."
        else
            echo "  DNS: All ${dns_queries} DNS queries resolved cleanly with no errors."
        fi

        # ── Reachability ─────────────────────────────────────────────────────
        echo ""
        if [ "${nc_rc:-1}" -eq 0 ]; then
            echo "  Reachability: The destination port is OPEN and accepting connections."
        elif [ "${tcp_syn:-0}" -gt 0 ] && [ "${tcp_synack:-0}" -eq 0 ]; then
            echo "  Reachability: ${tcp_syn} SYN packet(s) were sent but no SYN-ACK was received."
            echo "       The port is most likely FILTERED by a firewall or the host is unreachable."
            echo "       Check NSGs, Azure Firewall rules, or on-premises firewall ACLs."
        elif [ "${tcp_synack:-0}" -gt 0 ]; then
            echo "  Reachability: A SYN-ACK was observed in the capture (the server responded) but"
            echo "       the nc test still failed — this may be a timing issue or brief instability."
        else
            echo "  Reachability: The connection was refused or no packets were exchanged."
            echo "       Confirm the service is running on port $target_port and accepting connections."
        fi

        # ── Latency ──────────────────────────────────────────────────────────
        echo ""
        local avg_int_l
        avg_int_l=$(awk -v v="${tcp_avg_rtt:-0}" 'BEGIN{printf "%d", int(v)}')
        if [ "${tcp_total:-0}" -eq 0 ]; then
            echo "  Latency: No TCP packets were captured, so RTT cannot be measured."
        elif [ "$avg_int_l" -ge 200 ]; then
            echo "  Latency: Average RTT is ${tcp_avg_rtt}ms (max ${tcp_max_rtt}ms) — this is HIGH."
            echo "       Latency over 200ms will noticeably degrade interactive application performance."
            echo "       Check network path, routing, or whether the target is geographically distant."
        elif [ "$avg_int_l" -ge 100 ]; then
            echo "  Latency: Average RTT is ${tcp_avg_rtt}ms (max ${tcp_max_rtt}ms) — slightly elevated."
            echo "       This is within acceptable range for cross-region traffic but may affect"
            echo "       latency-sensitive workloads."
        else
            echo "  Latency: Average RTT is ${tcp_avg_rtt}ms (max ${tcp_max_rtt}ms) — within normal range."
        fi

        # ── Timeouts ─────────────────────────────────────────────────────────
        echo ""
        if [ "${tcp_syn:-0}" -gt 0 ] && [ "${tcp_synack:-0}" -eq 0 ] && [ "${tcp_retrans:-0}" -gt 0 ]; then
            echo "  Timeouts: The TCP handshake timed out — SYN packets were retransmitted with no"
            echo "       response. The OS retransmitted the SYN because it never received a SYN-ACK."
            echo "       This is a strong indicator of a firewall DROP rule (as opposed to a REJECT,"
            echo "       which returns a RST immediately)."
        elif [ "${tcp_zw:-0}" -gt 0 ]; then
            echo "  Timeouts: ${tcp_zw} zero-window event(s) detected — the receiving side's TCP buffer"
            echo "       was full, forcing the sender to pause transmission. This can cause application-"
            echo "       level timeouts if the condition persists. Investigate slow consumers or"
            echo "       large payload sizes relative to the receiver's buffer."
        else
            echo "  Timeouts: No timeout indicators detected."
        fi

        # ── Packet Drops ─────────────────────────────────────────────────────
        echo ""
        local drop_total=$(( ${tcp_retrans:-0} + ${tcp_ls:-0} + ${tcp_da:-0} ))
        if [ "$drop_total" -gt 0 ]; then
            echo "  Packet Loss: Packet loss indicators were found in the capture:"
            [ "${tcp_retrans:-0}" -gt 0 ] && echo "    - ${tcp_retrans} retransmission(s): packets that had to be re-sent because no ACK was received."
            [ "${tcp_ls:-0}"     -gt 0 ] && echo "    - ${tcp_ls} lost segment(s): tshark detected a gap in TCP sequence numbers."
            [ "${tcp_da:-0}"     -gt 0 ] && echo "    - ${tcp_da} duplicate ACK(s): the receiver repeatedly asking for the same missing segment."
            echo "       Together these indicate the network is dropping or reordering packets between"
            echo "       the two hosts. Investigate the network path, MTU mismatches, or NIC errors."
        else
            echo "  Packet Loss: No retransmissions, lost segments, or duplicate ACKs — the network"
            echo "       path appears clean."
        fi

        # ── Connection Resets / Closes ────────────────────────────────────────
        echo ""
        if [ "${tcp_rst:-0}" -gt 0 ] && [ "${tcp_fin:-0}" -gt 0 ]; then
            echo "  Connection Resets: ${tcp_rst} RST and ${tcp_fin} FIN packet(s) observed."
            echo "       RSTs indicate connections were forcibly terminated — typically by a firewall,"
            echo "       load balancer idle timeout, or the application itself. FINs indicate normal"
            echo "       graceful closes. If RSTs appear mid-stream (not just at start), the connection"
            echo "       was torn down unexpectedly — check idle timeout settings."
        elif [ "${tcp_rst:-0}" -gt 0 ]; then
            echo "  Connection Resets: ${tcp_rst} RST packet(s) detected — connections were forcibly closed."
            echo "       Common causes: firewall reject rule, application crash or restart, load balancer"
            echo "       idle timeout exceeded, or the server refused the connection on that port."
        elif [ "${tcp_fin:-0}" -gt 0 ]; then
            echo "  Connection Closes: ${tcp_fin} FIN packet(s) — connections were closed gracefully."
            echo "       This is normal behaviour for well-behaved request/response traffic."
        else
            echo "  Connection Closes: No RST or unexpected FIN packets observed."
        fi

        echo ""
        echo "  Full packet data available for manual review: $pcap_file"
        echo ""
    } | tee -a "$LOG_FILE"

    log_message "----------------------------------------------------------"
    log_message "Diagnostics complete: $target_ip:$target_port"
    log_message "----------------------------------------------------------"
}

# Tests connectivity to a target on specified ports.
# Usage: test_connectivity "target.com" "80" "443"
test_connectivity() {
    local target="$1"
    # Create an array of ports from the rest of the arguments
    local ports=("${@:2}")

    log_message "*** Starting tests for $target on port(s): ${ports[*]} ***"
    log_message "**********************************************************"
    
    # Check for required tools actually used in diagnostics
    check_tools "nc" "tcpdump" "tshark"

    for port in "${ports[@]}"; do
        run_diagnostics "$target" "$port"
    done
    log_message "**********************************************************"
    generate_html_report
}

# RUN 
run_interactive() {
    log_message "*** Beginning tests in Interactive Mode ***"
    log_message "**********************************************************"
    # nc, tcpdump, tshark are used in run_diagnostics; ss/netstat for connection detection
    check_tools "nc" "tcpdump" "tshark"

    local target_ip=""
    local target_port=""

    # Detect outbound IP and port.
    # Prompt only for port number
    read -p "Enter the destination Port to test: " target_port

    # Validate port
    if ! validate_port "$target_port"; then
        log_message "Error: Invalid port specified: '$target_port'. Must be an integer between 1-65535."
        exit 1
    fi

    local connection
    local peer_field
    local proc_field
    log_message "Detecting active outbound connection for port $target_port..."

    # Prefer 'ss' (modern replacement for netstat); fall back to 'netstat'
    if command -v ss &>/dev/null; then
        # ss output: netid state recv-q send-q local-addr:port peer-addr:port process
        # Fields:    $1    $2    $3     $4     $5               $6             $7
        connection=$(ss -tunp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | grep -v ':22 ' | grep ":$target_port ")
        peer_field=6
        proc_field=7
    elif command -v netstat &>/dev/null; then
        # netstat output: proto recv-q send-q local-addr foreign-addr state pid/prog
        # Fields:         $1    $2     $3     $4         $5           $6    $7
        connection=$(netstat -tunp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | grep -v ':22 ' | grep ":$target_port ")
        peer_field=5
        proc_field=7
    else
        log_message "Error: Neither 'ss' nor 'netstat' is available. Cannot detect active connections."
        exit 1
    fi

    if [ -z "$connection" ]; then
        log_message "No ACTIVE outbound connection found for port $target_port. If possible, trigger outbound n/w transactions and try again."
        exit 0
    fi

    target_ip=$(echo "$connection" | awk -v f="$peer_field" '{print $f}' | cut -d':' -f1 | sed 's/\[//;s/\]//' | head -n1)
    # Extract Process name
    local process_info
    local process_name
    process_info=$(echo "$connection" | awk -v f="$proc_field" '{print $f}' | head -n1)
    # ss wraps process info as users:(("name",pid=N,fd=M)); netstat uses pid/name
    if [[ "$process_info" == users* ]]; then
        process_name=$(echo "$process_info" | grep -oP '"\K[^"]+' | head -n1)
    else
        process_name=$(echo "$process_info" | cut -d'/' -f2)
    fi

    read -p "Detected application process: $process_name , destination: $target_ip:$target_port. Proceed with diagnostics? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_message "Diagnostics canceled by user."
        echo "Run diagnostics manually as needed. Ex: nwutils <fqdn> <port>. See nwutils -h for more options."
        exit 0
    fi
    run_diagnostics "$target_ip" "$target_port"
    log_message "**********************************************************"
    generate_html_report
}

# ==============================================================================
# HTML REPORT GENERATOR
# Reads the plain-text log file and produces a styled, self-contained HTML
# report covering only the current run (from the last banner marker onward).
# Output: $LOG_DIR/nwutils_report.html  (overwritten on each run)
# ==============================================================================
generate_html_report() {
    local html_file="$LOG_DIR/nwutils_report.html"
    local gen_ts
    gen_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # ── Scope to current run: find the last banner line ──────────────────────
    local run_start=1
    local last_match
    last_match=$(grep -n 'Network Diagnostics Script Version:' "$LOG_FILE" \
                 | tail -1 | cut -d: -f1)
    [ -n "$last_match" ] && run_start="$last_match"

    # ── Pre-process log into a temp file ─────────────────────────────────────
    # Strip ANSI colour codes → HTML-escape &, <, > → inject span classes
    local tmp_body
    tmp_body=$(mktemp)
    tail -n +"$run_start" "$LOG_FILE" \
    | sed \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
    | sed \
        -e 's/\bSUCCESS\b/<span class="ok">SUCCESS<\/span>/g' \
        -e 's/\bFAILING\b/<span class="fl">FAILING<\/span>/g' \
        -e 's/\bFAILED\b/<span class="fl">FAILED<\/span>/g' \
        -e 's/\bHEALTHY\b/<span class="ok">HEALTHY<\/span>/g' \
        -e 's/\bDEGRADED\b/<span class="dg">DEGRADED<\/span>/g' \
        -e 's/\bSUSPECTED\b/<span class="fl">SUSPECTED<\/span>/g' \
        -e 's/\bDETECTED\b/<span class="fl">DETECTED<\/span>/g' \
        -e 's/\bELEVATED\b/<span class="wn">ELEVATED<\/span>/g' \
        -e 's/\bWARNING\b/<span class="wn">WARNING<\/span>/g' \
        -e 's/\bPARTIAL\b/<span class="wn">PARTIAL<\/span>/g' \
        -e 's/!! NXDOMAIN/<span class="fl">!! NXDOMAIN<\/span>/g' \
        -e 's/!! SERVFAIL/<span class="fl">!! SERVFAIL<\/span>/g' \
        -e 's/\[SLOW&gt;1s\]/<span class="wn">[SLOW&gt;1s]<\/span>/g' \
    > "$tmp_body"

    # ── Write HTML ────────────────────────────────────────────────────────────
    {
        cat <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>nwutils — Network Diagnostics Report</title>
<style>
/* ── Design tokens ──────────────────────────────────────── */
:root {
  --bg:       #0d1117;
  --surface:  #161b22;
  --surface2: #1c2128;
  --surface3: #22272e;
  --border:   #30363d;
  --text:     #c9d1d9;
  --muted:    #8b949e;
  --accent:   #58a6ff;
  --green:    #3fb950;
  --yellow:   #d29922;
  --red:      #f85149;
  --cyan:     #39c5cf;
  --purple:   #a371f7;
}

/* ── Reset & base ───────────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  line-height: 1.6;
  padding: 32px 24px;
  max-width: 1440px;
  margin: 0 auto;
}

/* ── Page header ────────────────────────────────────────── */
.page-header {
  display: flex;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 28px;
}
.page-header .icon {
  font-size: 2.4rem;
  line-height: 1;
  flex-shrink: 0;
}
.page-header h1 {
  color: #ffffff;
  font-size: 1.75rem;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.page-header .subtitle {
  color: var(--muted);
  font-size: 0.875rem;
  margin-top: 4px;
}

/* ── Meta card (version / paths) ────────────────────────── */
.meta-card {
  background: linear-gradient(135deg, var(--surface) 0%, var(--surface2) 100%);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 16px 20px;
  margin-bottom: 24px;
  display: flex;
  flex-wrap: wrap;
  gap: 20px;
}
.meta-item { display: flex; flex-direction: column; gap: 2px; }
.meta-label {
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}
.meta-value {
  font-family: "Cascadia Code", "Fira Code", "SF Mono", Consolas, monospace;
  font-size: 0.82rem;
  color: var(--accent);
}

/* ── Collapsible sections ───────────────────────────────── */
.section {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  margin-bottom: 12px;
  overflow: hidden;
  transition: box-shadow 0.2s;
}
.section:hover { box-shadow: 0 2px 14px rgba(0,0,0,0.35); }

.section-header {
  background: linear-gradient(135deg, var(--surface2) 0%, var(--surface3) 100%);
  padding: 13px 18px;
  font-weight: 600;
  font-size: 0.9rem;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  display: flex;
  justify-content: space-between;
  align-items: center;
  color: var(--text);
  transition: background 0.15s;
  user-select: none;
}
.section-header:hover {
  background: linear-gradient(135deg, var(--surface3) 0%, #2d333b 100%);
}
.section-header .step-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: rgba(88, 166, 255, 0.12);
  border: 1px solid rgba(88, 166, 255, 0.25);
  color: var(--accent);
  font-size: 0.72rem;
  font-weight: 700;
  border-radius: 5px;
  padding: 1px 7px;
  margin-right: 10px;
  font-family: "Cascadia Code", "Fira Code", Consolas, monospace;
  letter-spacing: 0.02em;
}
.section-header .chevron {
  font-size: 0.65rem;
  opacity: 0.45;
  transition: transform 0.25s ease;
}
.section-header.collapsed .chevron { transform: rotate(-90deg); }

.section-body { padding: 16px 20px; overflow-x: auto; }

/* ── Monospace log output ───────────────────────────────── */
pre {
  font-family: "Cascadia Code", "Fira Code", "SF Mono", Consolas, monospace;
  font-size: 0.8rem;
  line-height: 1.65;
  white-space: pre;
  margin: 0;
}
.log-line {
  display: block;
  padding: 1px 4px;
  border-radius: 3px;
  transition: background 0.1s;
}
.log-line:hover { background: rgba(136, 198, 255, 0.06); }
.ts { color: var(--muted); font-size: 0.75rem; }
.tool-tag { color: var(--cyan); }
.stream-label { color: var(--purple); font-weight: 600; }
.sep-line { color: var(--border); opacity: 0.5; }
.banner-line { color: var(--accent); }

/* ── Status chips ───────────────────────────────────────── */
.ok   { color: var(--green);  font-weight: 600; }
.wn   { color: var(--yellow); font-weight: 600; }
.fl   { color: var(--red);    font-weight: 600; }
.dg   { color: var(--yellow); font-weight: 700; }

/* ── Health report table ────────────────────────────────── */
.health-table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  font-family: "Cascadia Code", "Fira Code", Consolas, monospace;
  font-size: 0.82rem;
  border-radius: 8px;
  overflow: hidden;
  border: 1px solid var(--border);
}
.health-table tr:not(:last-child) td,
.health-table tr:not(:last-child) th { border-bottom: 1px solid var(--border); }
.health-table td, .health-table th {
  padding: 10px 16px;
  vertical-align: middle;
}
.health-table th {
  background: var(--surface2);
  text-align: left;
  color: var(--accent);
  font-weight: 600;
  white-space: nowrap;
  width: 180px;
}
.health-table td { color: var(--text); }
.health-table tr:hover td { background: rgba(136, 198, 255, 0.03); }
.health-table .overall-row th,
.health-table .overall-row td {
  background: rgba(88, 166, 255, 0.06);
  font-weight: 700;
  font-size: 0.9rem;
}

/* ── Summary prose box ──────────────────────────────────── */
.summary-box {
  background: var(--surface2);
  border: 1px solid var(--border);
  border-left: 3px solid var(--accent);
  border-radius: 0 8px 8px 0;
  padding: 16px 20px;
  font-size: 0.88rem;
  line-height: 1.75;
  white-space: pre-wrap;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}

/* ── Footer ─────────────────────────────────────────────── */
footer {
  text-align: center;
  color: var(--muted);
  font-size: 0.78rem;
  margin-top: 40px;
  padding-top: 20px;
  border-top: 1px solid var(--border);
}

/* ── Print overrides ─────────────────────────────────────── */
@media print {
  body { background: #fff; color: #1a1a1a; padding: 16px; }
  .section { border-color: #ccc; box-shadow: none; }
  .section-header { background: #f0f0f0; color: #1a1a1a; }
  pre { font-size: 0.7rem; }
  .ts { color: #666; }
  .ok { color: #1a7f37; } .wn { color: #9a6700; } .fl { color: #cf222e; }
  .sep-line { color: #ccc; }
  .banner-line { color: #0550ae; }
  .health-table { border-color: #d0d7de; }
  .health-table th { background: #f6f8fa; color: #0550ae; }
  .meta-card { background: #f6f8fa; border-color: #d0d7de; }
  .summary-box { background: #f6f8fa; border-color: #d0d7de; border-left-color: #0550ae; }
}
</style>
<script>
function toggleSection(hdr) {
    var body = hdr.nextElementSibling;
    var isHidden = body.style.display === 'none';
    body.style.display = isHidden ? '' : 'none';
    hdr.classList.toggle('collapsed', !isHidden);
}
</script>
</head>
<body>
HTMLEOF

        # Page header
        printf '<div class="page-header">\n'
        printf '  <div class="icon">&#128269;</div>\n'
        printf '  <div>\n'
        printf '    <h1>nwutils &mdash; Network Diagnostics Report</h1>\n'
        printf '    <div class="subtitle">Generated: %s</div>\n' "$gen_ts"
        printf '  </div>\n'
        printf '</div>\n'

        # Meta card
        printf '<div class="meta-card">\n'
        printf '  <div class="meta-item"><span class="meta-label">Version</span><span class="meta-value">%s</span></div>\n' "$SCRIPT_VERSION"
        printf '  <div class="meta-item"><span class="meta-label">Log File</span><span class="meta-value">%s</span></div>\n' "$LOG_FILE"
        printf '  <div class="meta-item"><span class="meta-label">Log Directory</span><span class="meta-value">%s</span></div>\n' "$LOG_DIR"
        printf '</div>\n'

        # ── Process each log line ─────────────────────────────────────────────
        local section_open=false
        local in_health_table=false
        local in_summary=false
        local current_step=""
        local current_title=""

        while IFS= read -r line; do
            # Split off the timestamp prefix [YYYY-MM-DD HH:MM:SS]
            local ts_part="" rest="$line"
            if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\]\ (.*) ]]; then
                ts_part="${BASH_REMATCH[1]}"
                rest="${BASH_REMATCH[2]}"
            fi
            local esc_ts=""
            [ -n "$ts_part" ] && esc_ts="<span class=\"ts\">[$ts_part]</span> "

            # ── Skip banner boilerplate ───────────────────────────────────────
            if [[ "$rest" == *"Network Diagnostics Script Version:"* ]] || \
               [[ "$rest" == "*** "* ]] || \
               [[ "$rest" == "**"* ]]; then
                continue
            fi

            # ── Detect section headers: [1/5], [5b/6], [6/6], etc. ───────────
            if [[ "$rest" =~ ^\[([0-9]+[a-d]?/[0-9]+)\](\ )?(.*) ]]; then
                local step_id="${BASH_REMATCH[1]}"
                local step_title="${BASH_REMATCH[3]}"

                # Close any open section
                if $in_summary;       then printf '</div>\n'; in_summary=false; fi
                if $in_health_table;  then printf '</table>\n</div>\n'; in_health_table=false; fi
                $section_open && printf '</pre></div></div>\n'
                section_open=true
                current_step="$step_id"
                current_title="${step_title:-Section $step_id}"

                printf '<div class="section">\n'
                printf '<div class="section-header" onclick="toggleSection(this)">\n'
                printf '  <span><span class="step-badge">%s</span>%s</span>\n' \
                       "$step_id" "$current_title"
                printf '  <span class="chevron">&#9660;</span>\n'
                printf '</div>\n'
                printf '<div class="section-body"><pre>\n'
                continue
            fi

            # ── Detect "Starting diagnostics" run separator ───────────────────
            if [[ "$rest" == "Starting diagnostics:"* ]]; then
                if $in_summary;      then printf '</div>\n'; in_summary=false; fi
                if $in_health_table; then printf '</table>\n</div>\n'; in_health_table=false; fi
                $section_open && { printf '</pre></div></div>\n'; section_open=false; }

                section_open=true
                printf '<div class="section">\n'
                printf '<div class="section-header" onclick="toggleSection(this)">\n'
                printf '  <span>&#128640; %s</span>\n' "$rest"
                printf '  <span class="chevron">&#9660;</span>\n'
                printf '</div>\n'
                printf '<div class="section-body"><pre>\n'
                continue
            fi

            # ── Health report rows: "  | Field | Value |" ────────────────────
            if [[ "$rest" =~ ^[[:space:]]*\|.*\|$ ]]; then
                if ! $in_health_table; then
                    printf '</pre><div>\n'
                    printf '<table class="health-table">\n'
                    in_health_table=true
                fi
                # Strip leading/trailing whitespace and outer pipes
                local row="${rest#"${rest%%[! ]*}"}"   # ltrim
                row="${row#|}"
                row="${row%|}"
                # Split on | into two cells: key | value
                local key="${row%%|*}"
                local val="${row#*|}"
                key="${key#"${key%%[! ]*}"}"; key="${key%"${key##*[! ]}"}"
                val="${val#"${val%%[! ]*}"}"; val="${val%"${val##*[! ]}"}"

                # Skip pure-separator rows (+---+) 
                [[ "$key" =~ ^[+\-]+$ ]] && continue

                if [[ "$key" == "OVERALL STATUS" ]]; then
                    printf '<tr class="overall-row"><th>%s</th><td>%s</td></tr>\n' "$key" "$val"
                else
                    printf '<tr><th>%s</th><td>%s</td></tr>\n' "$key" "$val"
                fi
                continue
            fi
            # Close health table when a non-table line follows
            if $in_health_table; then
                printf '</table>\n</div>\n<pre>\n'
                in_health_table=false
            fi

            # ── Plain-English Summary: collect into styled prose box ──────────
            if [[ "$rest" == *"Plain-English Summary"* ]]; then
                # section header already handled above; mark that next lines are summary prose
                in_summary=false   # will open on first prose line below
            fi
            # Prose lines inside the summary (indented, no tool tag)
            if $section_open && [[ "$current_step" == "6/6" ]] && ! $in_summary; then
                if [[ "$rest" =~ ^[[:space:]]{2}(Target:|Connectivity|DNS:|Reachability:|Latency:|Timeouts:|Packet|Connection) ]]; then
                    printf '</pre><div class="summary-box">'
                    in_summary=true
                fi
            fi
            if $in_summary; then
                printf '%s\n' "$rest"
                continue
            fi

            # ── Separator lines ───────────────────────────────────────────────
            if [[ "$rest" =~ ^={10,}$ ]] || [[ "$rest" =~ ^-{10,}$ ]] || \
               [[ "$rest" == "+--"*  ]] || [[ "$rest" == "- - -"* ]]; then
                printf '<span class="log-line sep-line">%s</span>\n' "$rest"
                continue
            fi

            # ── TCP stream labels ─────────────────────────────────────────────
            if [[ "$rest" == *"[ TCP STREAM"* ]]; then
                printf '<span class="log-line stream-label">%s</span>\n' "$rest"
                continue
            fi

            # ── Tool-tagged lines: "  [dns]", "  [nc]", "  [curl]", etc. ─────
            if [[ "$rest" =~ ^([[:space:]]*)\[([a-z]+)\](.*) ]]; then
                local indent="${BASH_REMATCH[1]}"
                local tag="${BASH_REMATCH[2]}"
                local tail="${BASH_REMATCH[3]}"
                printf '<span class="log-line">%s%s<span class="tool-tag">[%s]</span>%s</span>\n' \
                       "$esc_ts" "$indent" "$tag" "$tail"
                continue
            fi

            # ── Default log line ──────────────────────────────────────────────
            printf '<span class="log-line">%s%s</span>\n' "$esc_ts" "$rest"

        done < "$tmp_body"

        # Close any remaining open structures
        $in_summary      && printf '</div>\n'
        $in_health_table && printf '</table>\n</div>\n'
        $section_open    && printf '</pre></div></div>\n'

        printf '<footer>nwutils v%s &mdash; Report generated %s</footer>\n' \
               "$SCRIPT_VERSION" "$gen_ts"
        printf '</body>\n</html>\n'

    } > "$html_file"

    rm -f "$tmp_body"
    log_message "HTML report: $html_file"
}

# Show help
show_help() {
    echo "Network Diagnostics Script"
    echo "--------------------------"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install                 Detect OS and install required networking tools."
    echo "                          (Requires root/sudo privileges)"
    echo ""
    echo "  <fqdn_or_ip>            Test connectivity to <fqdn_or_ip> on ports 80 and 443."
    echo "                          Prompts for a log file location."
    echo ""
    echo "  <fqdn_or_ip> <port>     Test connectivity to <fqdn_or_ip> on the specified <port>."
    echo "                          Prompts for a log file location."
    echo ""
    echo "  run                     Run interactive diagnostics."
    echo "                          - Detects outbound connections (via netstat)"
    echo "                          - Prompts for target"
    echo "                          - Runs nslookup, connectivity, and latency tests"
    echo "                          - Captures 1 minute of packets (requires root/sudo)"
    echo ""
    echo "  help (or no args)       Show this help message."
    echo ""
    echo "Global Log File: $LOG_FILE"
    echo "Packet Captures: $PACKET_CAPTURE_FILE (for 'run' mode)"
    echo "HTML Report:     $LOG_DIR/nwutils_report.html"
}

# Show script version
show_version() {
    echo "Network Diagnostics Script - Version $SCRIPT_VERSION"
}

# ==============================================================================
# MAIN SCRIPT
# Parse command-line arguments
# ==============================================================================

# No arguments: Show help
if [ "$#" -eq 0 ]; then
    show_help
    exit 0
fi

# Handle specific commands first
case "$1" in
    install)
        install_tools
        exit $?
        ;;
    run)
        run_interactive
        exit $?
        ;;
    help)
        show_help
        exit 0
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    -v|--version)
        show_version
        exit 0
        ;;
esac

# --- Handle FQDN/IP commands ---
# If not above (install, run, help), the cmdline arguments must be fqdn/ip and/or port number

TARGET_PORT=""
TARGET_FQDN="$1"
if ! validate_host "$TARGET_FQDN"; then
    log_message "Error: Invalid hostname or IP: '$TARGET_FQDN'"
    exit 1
fi
if [ "$#" -eq 1 ]; then
    test_connectivity "$TARGET_FQDN" "80" "443"
elif [ "$#" -eq 2 ]; then
    TARGET_PORT="$2"
    if ! validate_port "$TARGET_PORT"; then
        log_message "Error: Invalid port specified: '$TARGET_PORT'. Must be a number between 1 and 65535."
        exit 1
    fi
    test_connectivity "$TARGET_FQDN" "$TARGET_PORT"
else
    log_message "Error: Incorrect or too many arguments provided"
    show_help
    exit 1
fi

exit 0