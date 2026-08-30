#!/bin/bash

# ==============================================================================
# Basic Network Diagnostics Script for Azure Linux Environments
# Author: Ragu Karuturi 
# This script provides multiple functions for network troubleshooting:
# 1. install: Installs a suite of networking tools based on the detected OS.
# 2. <target> [port]: Tests connectivity to a target FQDN or IP. Default ports 80 and 443.
# 3. run: Interactive mode to detect outbound connections and run diagnostics.
# ==============================================================================

SCRIPT_VERSION="2.0.0"

# Default capture duration (seconds) for capture/trace/run. Ctrl-C stops early.
CAPTURE_DURATION_DEFAULT=180

# Cross-function session state (valid for a single script invocation only)
CAPTURED_PCAP=""   # last .pcap produced by do_capture
PROBE_NC_RC=""     # reachability result code from the most recent do_probe
PROBE_TARGET=""    # target that PROBE_NC_RC applies to
USE_ASCII=0        # 1 = plain-ASCII UI (no box-drawing); set by --ascii

# Log directory selection, in priority order, so the tool runs anywhere:
#   1) $NWUTILS_LOG_DIR   explicit override (also handy for testing)
#   2) /home/Logfiles     Azure App Service persistent storage
#   3) /Appuserlogs       custom containers / IaaS (enable storage in App Service)
#   4) $TMPDIR|/tmp       fallback that works on almost every Linux
#   5) ./nwutils-out      last resort in the current directory
select_log_dir() {
    local candidates=() d
    [ -n "${NWUTILS_LOG_DIR:-}" ] && candidates+=("$NWUTILS_LOG_DIR")
    candidates+=("/home/Logfiles" "/Appuserlogs" "${TMPDIR:-/tmp}/nwutils" "./nwutils-out")
    for d in "${candidates[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        [ -w "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}
LOG_DIR="$(select_log_dir)" || {
    echo "Failed to find a writable log directory. Set NWUTILS_LOG_DIR to override." >&2
    exit 1
}

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

# Resolve a hostname to its first IPv4 address.
# Echoes the IP, or the original input if it is already an IP or cannot be resolved.
# Used so the tcpdump BPF filter and the later tshark ip.addr filter agree.
resolve_host() {
    local host="$1"
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$host"; return 0
    fi
    local ip=""
    if command -v dig &>/dev/null; then
        ip=$(dig +short "$host" A 2>/dev/null | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
    fi
    if [ -z "$ip" ] && command -v getent &>/dev/null; then
        ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
    fi
    if [ -z "$ip" ] && command -v nslookup &>/dev/null; then
        ip=$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2; exit}' | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
    fi
    echo "${ip:-$host}"
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

# ==============================================================================
# PROBE — active, live tests (DNS + reachability + connectivity). No capture.
# Usage: do_probe <host_or_ip> <port>
# ==============================================================================
do_probe() {
    local target="$1"
    local target_port="$2"

    log_message "=========================================================="
    log_message "PROBE (active tests): $target  port $target_port"
    log_message "=========================================================="

    # --- DNS resolution ---
    log_message ""
    log_message "[probe 1/4] DNS Lookup"
    dns_lookup "$target"
    log_message "----------------------------------------------------------"

    # --- Reachability: nc (+ nmap when available) ---
    log_message ""
    log_message "[probe 2/4] Reachability test (nc / nmap) — is the port open, closed, or filtered?"
    local nc_output nc_rc
    nc_output=$(nc -zv -w 3 "$target" "$target_port" 2>&1)
    nc_rc=$?
    if [ $nc_rc -eq 0 ]; then
        log_message "  [nc] SUCCESS: $target:$target_port is reachable (port OPEN)."
        echo "  [nc] Detailed output: $nc_output" >> "$LOG_FILE"
    else
        log_message "  [nc] FAILED: $target:$target_port is NOT reachable."
        log_message "  [nc] Details: $nc_output"
        log_message "  [nc] Action: Check NSGs/Firewalls, validate IP/Port, or capture a trace (nwutils trace)."
    fi
    # nmap adds the open/closed/filtered distinction with a reason
    if command -v nmap &>/dev/null; then
        local nmap_out
        nmap_out=$(nmap -Pn -p "$target_port" --reason "$target" 2>/dev/null | grep -E "^${target_port}/|Host is")
        [ -n "$nmap_out" ] && echo "$nmap_out" | sed 's/^/  [nmap] /' | tee -a "$LOG_FILE"
    fi
    # Record reachability so a later do_analyze in the same run can use it
    PROBE_NC_RC="$nc_rc"
    PROBE_TARGET="$target"
    log_message "----------------------------------------------------------"

    # --- Connectivity: curl end-to-end (real HTTP status, works for HTTPS) ---
    log_message ""
    if [[ "$target_port" == "80" || "$target_port" == "443" || "$target_port" == "8080" || "$target_port" == "8443" ]]; then
        log_message "[probe 3/4] Connectivity test (curl) — end-to-end TLS + HTTP status + timing"
        local scheme="http"
        [[ "$target_port" == "443" || "$target_port" == "8443" ]] && scheme="https"
        local curl_out
        curl_out=$(curl -sk --max-time 5 -o /dev/null \
            -w "HTTP %{http_code} | DNS: %{time_namelookup}s | Connect: %{time_connect}s | TLS: %{time_appconnect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s" \
            "${scheme}://${target}:${target_port}/" 2>&1)
        log_message "  [curl] $curl_out"
    else
        log_message "[probe 3/4] Connectivity test skipped (port $target_port is not a standard web port for curl)"
    fi
    log_message "----------------------------------------------------------"

    # --- TCP connect latency: nping ---
    log_message ""
    log_message "[probe 4/4] TCP connect latency (nping)"
    run_nping "$target" "$target_port"
    log_message "----------------------------------------------------------"
    log_message "PROBE complete: $target:$target_port"
    log_message "=========================================================="
}

# ==============================================================================
# CAPTURE — record a tcpdump (.pcap) of target traffic + DNS. Needs root/sudo.
# Usage: do_capture <host_or_ip> <port> [duration_seconds]
# Sets global CAPTURED_PCAP to the resulting file path.
# ==============================================================================
do_capture() {
    local target="$1"
    local target_port="$2"
    local duration="${3:-$CAPTURE_DURATION_DEFAULT}"

    # Resolve to an IP so the tcpdump filter and later tshark analysis agree
    local target_ip
    target_ip=$(resolve_host "$target")

    local safe_target="${target//[^a-zA-Z0-9]/_}"
    local pcap_file="$LOG_DIR/nwutils_${safe_target}_${target_port}_$(date +%s).pcap"
    CAPTURED_PCAP="$pcap_file"

    log_message "=========================================================="
    log_message "CAPTURE: $target ($target_ip) port $target_port — up to ${duration}s (Ctrl-C to stop early)"
    log_message "=========================================================="

    # Filter at capture time to reduce noise: target host+port plus all DNS
    local -a tcpdump_args=(-i any -tttt -nn -U -w "$pcap_file"
        "(host $target_ip and port $target_port) or port 53")

    # Trap Ctrl-C so it stops tcpdump but lets the script continue to analysis
    trap 'log_message "  Capture interrupted (Ctrl-C) — stopping tcpdump and continuing..."' INT
    if [ "$EUID" -ne 0 ]; then
        log_message "  Using sudo for tcpdump..."
        sudo timeout "$duration" tcpdump "${tcpdump_args[@]}" >/dev/null 2>&1
    else
        timeout "$duration" tcpdump "${tcpdump_args[@]}" >/dev/null 2>&1
    fi
    trap - INT

    log_message "  Packet capture saved to: $pcap_file"
    log_message "=========================================================="
}

# ==============================================================================
# ANALYZE — offline analysis of a .pcap: DNS analysis, per-stream TCP table,
# health report, and plain-English summary. Needs neither root nor the network.
# Usage: do_analyze <pcap_file> [host_or_ip] [port]
# ==============================================================================
do_analyze() {
    local pcap_file="$1"
    local target="${2:-}"
    local target_port="${3:-}"

    # Resolve host to a numeric IP for tshark filters (ip.addr needs an IP)
    local target_ip=""
    [ -n "$target" ] && target_ip=$(resolve_host "$target")

    # Build the TCP display filter dynamically so standalone captures still work
    local tcp_filter="tcp"
    [ -n "$target_port" ] && tcp_filter="$tcp_filter && tcp.port == $target_port"
    [ -n "$target_ip" ]   && tcp_filter="$tcp_filter && ip.addr == $target_ip"

    log_message "=========================================================="
    log_message "ANALYZE: $pcap_file${target:+  (target $target${target_port:+:$target_port})}"
    log_message "=========================================================="

    # --- Pre-analysis checks ---
    log_message ""
    if [ ! -f "$pcap_file" ]; then
        log_message "  Error: Capture file not found: $pcap_file"
        return 1
    fi
    if [ ! -s "$pcap_file" ]; then
        log_message "  Warning: Pcap file is empty — capture failed or no matching packets were seen."
        log_message "  Hint: Ensure traffic to the target occurred during the capture window."
        return 1
    fi
    if ! command -v tshark &>/dev/null; then
        log_message "  [tshark] Not installed — skipping packet analysis. Pcap saved for manual review."
        return 1
    fi

    # Temp file used to pass numeric stats from awk subshells back to bash
    local stats_file
    stats_file=$(mktemp)
    # Seed reachability result if a probe ran for this same target in this run
    if [ -n "$PROBE_NC_RC" ] && [ "$PROBE_TARGET" == "$target" ]; then
        printf "nc_rc=%d\n" "$PROBE_NC_RC" > "$stats_file"
    else
        printf "nc_rc=%d\n" 1 > "$stats_file"
    fi

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
        -Y "$tcp_filter" \
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
    awk -F'\t' -v sf="$stats_file" -v tip="$target_ip" '
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
        srv_close=0; cli_close=0; unk_close=0;
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

        # Attribute the FIRST FIN/RST per stream to whoever sent it
        if ((flags ~ /R/ || flags ~ /F/) && !(stream in closed)) {
            closed[stream] = 1;
            if      (tip != "" && src == tip) srv_close++;
            else if (tip != "")               cli_close++;
            else                              unk_close++;
        }
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
        if (srv_close > 0 || cli_close > 0 || unk_close > 0)
            printf "  CLOSE: %d closed first by SERVER | %d by CLIENT | %d unattributed\n", srv_close, cli_close, unk_close;

        # Append TCP stats for health report
        printf "tcp_total=%d\n",    total   >> sf;
        printf "tcp_srv_close=%d\n", srv_close >> sf;
        printf "tcp_cli_close=%d\n", cli_close >> sf;
        printf "tcp_unk_close=%d\n", unk_close >> sf;
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

    # tshark passes are done; from here target_ip/target_port are display-only
    [ -z "$target_ip" ]   && target_ip="${target:-$(basename "$pcap_file")}"
    [ -z "$target_port" ] && target_port="all"

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

        # ── Who closed first (client vs server) ──────────────────────────────
        if [ "${tcp_srv_close:-0}" -gt 0 ] || [ "${tcp_cli_close:-0}" -gt 0 ]; then
            echo ""
            echo "  Who Closed First: ${tcp_srv_close:-0} stream(s) closed first by the SERVER (remote),"
            echo "       ${tcp_cli_close:-0} by the CLIENT (this host)${tcp_unk_close:+, ${tcp_unk_close} unattributed}."
            if [ "${tcp_srv_close:-0}" -gt "${tcp_cli_close:-0}" ]; then
                echo "       The remote end is initiating most closes — investigate server-side idle"
                echo "       timeouts, load-balancer limits, or upstream app restarts/crashes."
            elif [ "${tcp_cli_close:-0}" -gt 0 ]; then
                echo "       This host is initiating most closes — usually normal request completion,"
                echo "       but check client-side timeouts if closes look premature."
            fi
        fi

        echo ""
        echo "  Full packet data available for manual review: $pcap_file"
        echo ""
    } | tee -a "$LOG_FILE"

    log_message "----------------------------------------------------------"
    log_message "ANALYZE complete: $target_ip:$target_port"
    log_message "----------------------------------------------------------"
}

# ── UI helpers (simple, portable framing with ASCII fallback) ────────────────
NW_RULE="──────────────────────────────────────────────────────────────────────────────"
NW_RULE_ASCII="------------------------------------------------------------------------------"
ui_line() { if [ "${USE_ASCII:-0}" -eq 1 ]; then echo "$NW_RULE_ASCII"; else echo "$NW_RULE"; fi; }

# Best-effort reverse DNS (PTR) for display. Empty if none.
reverse_lookup() {
    local ip="$1" name="" TO=""
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo ""; return; }
    command -v timeout &>/dev/null && TO="timeout 2"
    if command -v dig &>/dev/null; then
        name=$($TO dig +short -x "$ip" 2>/dev/null | head -n1 | sed 's/\.$//')
    fi
    if [ -z "$name" ] && command -v getent &>/dev/null; then
        name=$($TO getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
    fi
    echo "$name"
}

# ── Outbound-connection detectors (ss → netstat → /proc fallback) ─────────────
# Each emits normalized lines: STATE|IP|PORT|PROCESS
_detect_ss() {
    ss -tnp state connected 2>/dev/null | awk '
    NR==1 && /State/ { next }
    {
        local_ap=""; peer_ap=""; proc="-"; n=0;
        for (i=1;i<=NF;i++) {
            if ($i ~ /:[0-9]+$/) { n++; if (n==1) local_ap=$i; else if (n==2) peer_ap=$i; }
            if ($i ~ /users:/) proc=$i;
        }
        if (peer_ap=="") next;
        st=$1; if (st !~ /^[A-Za-z-]+$/) st="ESTAB";
        pport=peer_ap; sub(/.*:/,"",pport);
        pip=peer_ap;   sub(/:[0-9]+$/,"",pip); gsub(/[][]/,"",pip);
        pname="-"; if (match(proc,/"[^"]+"/)) pname=substr(proc,RSTART+1,RLENGTH-2);
        print st "|" pip "|" pport "|" pname;
    }'
}
_detect_netstat() {
    netstat -tnp 2>/dev/null | awk '
    /^tcp/ {
        peer_ap=$5; st=$6; proc=$7;
        pport=peer_ap; sub(/.*:/,"",pport);
        pip=peer_ap;   sub(/:[0-9]+$/,"",pip); gsub(/[][]/,"",pip);
        pname=proc; sub(/.*\//,"",pname); if (pname=="") pname="-";
        print st "|" pip "|" pport "|" pname;
    }'
}
_detect_proc() {
    local f
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        awk 'NR>1 {
            st=$4; if (st!="01" && st!="02") next;
            split($3,r,":"); ipx=r[1]; portx=r[2];
            port=strtonum("0x" portx);
            if (length(ipx)==8) {
                a=strtonum("0x" substr(ipx,7,2)); b=strtonum("0x" substr(ipx,5,2));
                c=strtonum("0x" substr(ipx,3,2)); d=strtonum("0x" substr(ipx,1,2));
                ip=a"."b"."c"."d;
            } else ip="(ipv6)";
            print (st=="01"?"ESTAB":"SYN-SENT") "|" ip "|" port "|-";
        }' "$f" 2>/dev/null
    done
}

# Populate global DETECTED_CONNS[] with "COUNT|STATE|IP|PORT|PROC", busiest first.
detect_outbound_connections() {
    DETECTED_CONNS=()
    local raw=""
    if   command -v ss      &>/dev/null; then raw=$(_detect_ss)
    elif command -v netstat &>/dev/null; then raw=$(_detect_netstat)
    else                                      raw=$(_detect_proc)
    fi

    # Drop loopback, link-local, wildcard, and SSH(22)
    raw=$(printf '%s\n' "$raw" \
        | awk -F'|' 'NF>=3 && $2!="" && $2!="*" && $2!="0.0.0.0" && $2!="127.0.0.1" && $2!="::1" && $3!="22" && $2 !~ /^169\.254\./ {print}')

    declare -A cnt state
    local st ip port proc key
    while IFS='|' read -r st ip port proc; do
        [ -z "$ip" ] && continue
        key="$ip|$port|$proc"
        cnt["$key"]=$(( ${cnt["$key"]:-0} + 1 ))
        if [ "${state[$key]:-}" != "SYN-SENT" ]; then state["$key"]="$st"; fi
    done <<< "$raw"

    local sorted k
    sorted=$(for k in "${!cnt[@]}"; do printf '%s|%s|%s\n' "${cnt[$k]}" "${state[$k]}" "$k"; done | sort -t'|' -k1,1 -rn)
    while IFS= read -r k; do
        [ -n "$k" ] && DETECTED_CONNS+=("$k")
    done <<< "$sorted"
}

# ── TRACE = capture + analyze ─────────────────────────────────────────────────
do_trace() {
    local target="$1" target_port="$2" duration="${3:-$CAPTURE_DURATION_DEFAULT}"
    check_tools "tcpdump" "tshark"
    do_capture "$target" "$target_port" "$duration"
    do_analyze "$CAPTURED_PCAP" "$target" "$target_port"
}

# ── RUN = probe + trace + HTML report ─────────────────────────────────────────
do_run() {
    local target="$1" target_port="$2" duration="${3:-$CAPTURE_DURATION_DEFAULT}"
    check_tools "nc" "tcpdump" "tshark"
    log_message "**********************************************************"
    log_message "RUN: full workflow for $target:$target_port"
    log_message "**********************************************************"
    do_probe   "$target" "$target_port"
    do_capture "$target" "$target_port" "$duration"
    do_analyze "$CAPTURED_PCAP" "$target" "$target_port"
    generate_html_report
}

# ── CHECK = inventory installed tools ─────────────────────────────────────────
check_inventory() {
    log_message "*** Tool inventory ***"
    local tools="curl wget dig nslookup nc nmap nping tcpdump tshark ss netstat ip traceroute mtr iftop nethogs iptraf-ng nload lsof"
    local t present=0 total=0
    for t in $tools; do
        total=$((total+1))
        if command -v "$t" &>/dev/null; then
            printf "  +  %-14s installed\n" "$t" | tee -a "$LOG_FILE"
            present=$((present+1))
        else
            printf "  -  %-14s missing\n" "$t" | tee -a "$LOG_FILE"
        fi
    done
    log_message "Installed: $present / $total tools. Run 'nwutils install' to add the full toolkit."
}

# ── SUGGEST = print copy-paste commands tailored to a target ──────────────────
suggest_commands() {
    local host="${1:-<host>}" port="${2:-443}"
    cat <<EOF

nwutils — suggested manual commands for ${host}:${port}
(Copy-paste the ones you need. Nothing here is executed.)

DNS
  dig ${host}
  dig +trace ${host}
  dig -x <ip>                          # reverse lookup
  nslookup ${host}

Reachability (is the port open / closed / filtered?)
  nc -zv -w 5 ${host} ${port}
  nmap -p ${port} --reason ${host}
  nping --tcp-connect -p ${port} -c 5 ${host}

Connectivity (end-to-end: TLS + HTTP status + timing)
  curl -o /dev/null -s -w 'DNS:%{time_namelookup} TCP:%{time_connect} TLS:%{time_appconnect} TTFB:%{time_starttransfer} total:%{time_total} code:%{http_code}\n' https://${host}:${port}/
  curl -vvv https://${host}:${port}/ 2>&1 | head -50

Capture (needs root/sudo)
  tcpdump -i any -s 0 -tttt -U -nn -w trace.pcap '(host ${host} and port ${port}) or port 53'
  tcpdump -i any -nn -s 0 -w resets.pcap 'tcp[tcpflags] & (tcp-rst|tcp-fin) != 0'

Analyze a capture
  tshark -r trace.pcap -Y "dns"
  tshark -r trace.pcap -Y "tcp.flags.reset == 1"
  tshark -r trace.pcap -Y "tcp.analysis.retransmission"
  tshark -r trace.pcap -q -z conv,tcp

Or let nwutils do it for you
  nwutils probe ${host} ${port}
  nwutils trace ${host} ${port}
  nwutils run   ${host} ${port}
EOF
}

# ── INTERACTIVE = guided 3-stage menu (detect → confirm/edit → probe/trace/run)
run_interactive() {
    log_message "*** Interactive Mode ***"
    local sel_host="" sel_ip="" sel_port="" choice e np a

    while true; do
        # ---- Stage 1: detect outbound connections and pick one ----
        echo ""
        echo "Scanning active outbound connections..."
        detect_outbound_connections
        echo ""
        ui_line
        printf "  %-3s %-16s %-30s %-6s %-9s %s\n" "#" "PROCESS" "DESTINATION (PTR or IP)" "PORT" "STATE" "CONNS"
        ui_line
        if [ "${#DETECTED_CONNS[@]}" -eq 0 ]; then
            echo "  (none detected — choose [m] to enter a target manually)"
        else
            local i=1 entry c st ip port proc ptr flag
            for entry in "${DETECTED_CONNS[@]}"; do
                IFS='|' read -r c st ip port proc <<< "$entry"
                ptr=$(reverse_lookup "$ip")
                flag=""; [ "$st" = "SYN-SENT" ] && flag="  <- connecting/failing"
                printf "  %-3s %-16s %-30s %-6s %-9s %s%s\n" "$i" "${proc:0:16}" "${ptr:-$ip}" "$port" "$st" "$c" "$flag"
                i=$((i+1))
            done
        fi
        ui_line
        echo "  [1-N] select   [m] manual entry   [r] rescan   [q] quit"
        printf "> "; read -r choice

        case "$choice" in
            q|Q) echo "Leaving interactive mode."; return 0 ;;
            r|R) continue ;;
            '')  continue ;;
            m|M)
                printf "Enter destination host or IP: "; read -r sel_host
                [ -z "$sel_host" ] && { echo "No host entered."; continue; }
                validate_host "$sel_host" || { echo "Invalid host/IP."; continue; }
                sel_ip=$(resolve_host "$sel_host")
                printf "Enter destination port: "; read -r sel_port
                validate_port "$sel_port" || { echo "Invalid port."; continue; }
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DETECTED_CONNS[@]}" ]; then
                    local c st ip port proc
                    IFS='|' read -r c st ip port proc <<< "${DETECTED_CONNS[$((choice-1))]}"
                    sel_ip="$ip"; sel_port="$port"
                    sel_host=$(reverse_lookup "$ip"); [ -z "$sel_host" ] && sel_host="$ip"
                else
                    echo "Invalid selection."; continue
                fi
                ;;
        esac

        # ---- Stage 2: confirm / edit the target ----
        while true; do
            echo ""; ui_line
            echo "  Target"
            printf "    Host : %s\n" "${sel_host:-<none>}"
            printf "    IP   : %s\n" "${sel_ip:-<none>}"
            printf "    Port : %s\n" "${sel_port:-<none>}"
            ui_line
            echo "  [Enter] confirm   [h] edit host   [i] edit IP   [p] edit port   [b] back"
            printf "> "; read -r e
            case "$e" in
                '') break ;;
                h|H) printf "New host: "; read -r sel_host; [ -n "$sel_host" ] && sel_ip=$(resolve_host "$sel_host") ;;
                i|I) printf "New IP: ";   read -r sel_ip ;;
                p|P) printf "New port: "; read -r np; if validate_port "$np"; then sel_port="$np"; else echo "Invalid port."; fi ;;
                b|B) continue 2 ;;
                *) : ;;
            esac
        done

        if [ -z "$sel_port" ] || { [ -z "$sel_host" ] && [ -z "$sel_ip" ]; }; then
            echo "Target incomplete; returning to detection."; continue
        fi
        local tgt="${sel_host:-$sel_ip}"

        # ---- Stage 3: choose an action (probe / trace / run) ----
        while true; do
            echo ""; ui_line
            printf "  Target: %s (%s) : %s\n" "${sel_host:-$sel_ip}" "${sel_ip:-?}" "$sel_port"
            ui_line
            echo "    1  probe   active tests only  (DNS + reachability + connectivity)"
            echo "    2  trace   capture + analyze  (up to ${CAPTURE_DURATION_DEFAULT}s, Ctrl-C to stop)"
            echo "    3  run     everything         (probe + trace + report)"
            ui_line
            echo "    8  change target      9  quit"
            printf "Select [1-3, 8, 9]> "; read -r a
            case "$a" in
                1) do_probe "$tgt" "$sel_port"; generate_html_report ;;
                2) do_trace "$tgt" "$sel_port"; generate_html_report ;;
                3) do_run   "$tgt" "$sel_port" ;;
                8) break ;;
                9|q|Q) echo "Leaving interactive mode."; return 0 ;;
                *) echo "Invalid choice." ;;
            esac
        done
    done
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
    cat <<EOF
nwutils v$SCRIPT_VERSION — Linux Network Troubleshooting Utility
Works on any Linux: Azure App Service (Kudu & containers), Container Apps, AKS,
Azure / AWS / GCP VMs, and local VMs.

USAGE
  nwutils <command> [host] [port] [options]

SETUP
  install               Install the FULL networking toolkit.
  check                 Inventory which tools are installed.

ACTIVE (live tests, no capture)
  probe   <host> [port] DNS + reachability + connectivity tests, now.

PASSIVE (packet evidence)
  trace   <host> [port] Capture + analyze in one go
                        (up to ${CAPTURE_DURATION_DEFAULT}s; press Ctrl-C to stop early).
  capture <host> [port] Record a tcpdump (.pcap) only.
  analyze <file.pcap>   Analyze an existing capture (offline).

EVERYTHING
  run     <host> [port] probe + trace + unified report.

GUIDED / MANUAL
  interactive           Menu UI: pick a connection, choose probe/trace/run.
                        (aliases: int, i, menu)
  suggest [host] [port] Print copy-paste commands for your target
                        (no host = generic cheatsheet).

MISC
  help · version

OPTIONS
  -d, --duration <sec>  Capture length for capture/trace/run (default: ${CAPTURE_DURATION_DEFAULT}).
      --ascii           Plain-ASCII UI (no box-drawing characters).

MENTAL MODEL
  probe = active   ·   trace = passive (capture + analyze)   ·   run = both
  capture and analyze are the atomic halves of trace. Port defaults to 443.

TYPICAL WORKFLOWS
  Do it all:               nwutils run api.example.com 443
  Live tests only:         nwutils probe api.example.com 443
  Trace then read:         nwutils trace api.example.com 443
  Capture now, read later: nwutils capture api.example.com 443 -d 300
                           nwutils analyze /path/to/capture.pcap
  Guided menu:             nwutils interactive
  By hand:                 nwutils install && nwutils suggest api.example.com 443

NOTES
  • install & capture/trace need root/sudo. probe & analyze do not.
  • A bare 'nwutils <host> [port]' is shorthand for 'nwutils run <host> [port]'.
  • Ctrl-C during a capture stops tcpdump and proceeds straight to analysis.

Log file:    $LOG_FILE
HTML report: $LOG_DIR/nwutils_report.html
EOF
}

# Show script version
show_version() {
    echo "Network Diagnostics Script - Version $SCRIPT_VERSION"
}

# ==============================================================================
# MAIN SCRIPT — argument parsing and command dispatch
# ==============================================================================

# ── Parse global options out of the argument list, keep positionals in order ──
DURATION="$CAPTURE_DURATION_DEFAULT"
POSargs=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--duration)
            DURATION="$2"; shift 2
            if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
                echo "Error: --duration requires a number of seconds."; exit 1
            fi
            ;;
        --ascii)      USE_ASCII=1; shift ;;
        -h|--help)    show_help; exit 0 ;;
        -v|--version) show_version; exit 0 ;;
        --)           shift; while [ "$#" -gt 0 ]; do POSargs+=("$1"); shift; done ;;
        # Any other -word (e.g. -probe) is treated as a positional so dashed
        # command forms still work; the leading dash is normalized below.
        *) POSargs+=("$1"); shift ;;
    esac
done
set -- "${POSargs[@]}"

# No positional args: show help
if [ "$#" -eq 0 ]; then
    show_help
    exit 0
fi

# Normalize a leading dash on a verb (e.g. -probe → probe, --run → run)
CMD="$1"; CMD="${CMD#-}"; CMD="${CMD#-}"

case "$CMD" in
    install)
        install_tools; exit $? ;;
    check)
        check_inventory; exit $? ;;
    interactive|int|i|menu)
        run_interactive; exit $? ;;
    suggest)
        suggest_commands "$2" "$3"; exit 0 ;;
    help)
        show_help; exit 0 ;;
    version)
        show_version; exit 0 ;;
    probe|trace|capture|run)
        HOST="$2"
        if [ -z "$HOST" ]; then
            log_message "Error: '$CMD' requires a host. Example: nwutils $CMD api.example.com 443"
            exit 1
        fi
        if ! validate_host "$HOST"; then
            log_message "Error: Invalid hostname or IP: '$HOST'"
            exit 1
        fi
        PORT="${3:-443}"
        if ! validate_port "$PORT"; then
            log_message "Error: Invalid port: '$PORT'. Must be 1-65535."
            exit 1
        fi
        case "$CMD" in
            probe)   do_probe   "$HOST" "$PORT";              generate_html_report ;;
            capture) do_capture  "$HOST" "$PORT" "$DURATION" ;;
            trace)   do_trace    "$HOST" "$PORT" "$DURATION"; generate_html_report ;;
            run)     do_run      "$HOST" "$PORT" "$DURATION" ;;
        esac
        exit 0
        ;;
    analyze)
        PCAP="$2"
        if [ -z "$PCAP" ]; then
            log_message "Error: 'analyze' requires a .pcap file. Example: nwutils analyze trace.pcap [host] [port]"
            exit 1
        fi
        do_analyze "$PCAP" "$3" "$4"
        generate_html_report
        exit 0
        ;;
    *)
        # Backward-compatible shorthand: 'nwutils <host> [port]' == 'nwutils run ...'
        HOST="$1"
        if validate_host "$HOST"; then
            PORT="${2:-443}"
            if ! validate_port "$PORT"; then
                log_message "Error: Invalid port: '$PORT'. Must be 1-65535."
                exit 1
            fi
            do_run "$HOST" "$PORT" "$DURATION"
            exit 0
        fi
        log_message "Error: Unknown command or invalid host: '$1'"
        show_help
        exit 1
        ;;
esac

exit 0