
# Network Diagnostics Script for Azure Linux Environments

Bash script for network troubleshooting and diagnostics on Linux environments, including Azure App Services and IaaS VMs. This script helps detect name resolution, reachability and connectivity issues, measure latency, and capture network traffic for detailed analysis. Includes a summary analysis of timeouts, RTTs/latencies and retransmissions. 

---

## Features

- **Automated Tool Installation:** Detects OS and installs all required networking tools (`nmap`, `nc`, `tcpdump`, `tshark`, `nping`, etc.) across multiple Linux distributions (Ubuntu/Debian, RHEL, CBL-Mariner, Alpine). 
List of tools: nmap netcat-openbsd tcpdump dnsutils iproute2 iftop net-tools iptraf-ng nethogs nload curl wget lsof tshark. 
- **DNS Resolution:** Performs forward and reverse DNS lookup.  
- **Reachability Testing:** Checks if a target host and port are reachable and tests connectivity to upstream service. 
- **Latency Measurement:** Measures TCP Round Trip Times.
- **Packet Capture:** Captures TCP and DNS traffic to a `.pcap` file for detailed inspection.  
- **TCP Stream Analysis:** Generates SYN/SYN-ACK/ACK summaries, transmission btes, retransmissions, RTT, and SYN drop detection.
- **Interactive Mode:** Detects active outbound connections and guides you through diagnostics.  
- **Centralized Logging:** Logs all output to a timestamped log file.
---

## Usage modes

- **nwutils install :** Detects OS type and level and install tools
- **nwutils run :** Runs in interactive mode and prompts for destination port number and proceeds with all diagnostics and generates logs and trace files.  
- **nwutils FQDN and optionally PORT :** Similar to interactive mode but for the specified destination IP and Port. 
- **nwutil help or no args :** Help and more options
---

## Requirements

- Linux-based OS distros (Ubuntu, Debian, RHEL, CBL-Mariner, Alpine).  
- Root or sudo privileges for packet capture (`tcpdump`) and tool installation.  
- Internet connection for installing missing tools.

---

## Installation

1. Clone or download the script:

```bash
curl -fsSL https://raw.githubusercontent.com/slashroot79/nwutils/refs/heads/master/nwutils_install.sh | bash
```