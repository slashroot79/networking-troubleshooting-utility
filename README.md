# nwutils — Linux Network Troubleshooting Utility

A single Bash script for diagnosing outbound network problems on **any Linux** environment:
Azure App Service (Kudu console and containers), Azure Container Apps, AKS, Azure / AWS / GCP
VMs, and local VMs. It resolves DNS, tests reachability and end-to-end connectivity, captures
traffic with `tcpdump`, and analyzes the capture into a health report, a plain-English summary,
and a self-contained HTML report.

---

## Mental model

Three primary actions:

- **probe** — active live tests (DNS + reachability + connectivity). No capture.
- **trace** — passive evidence: capture a `.pcap`, then analyze it.
- **run** — everything: `probe` + `trace` + a unified report.

`capture` and `analyze` are the atomic halves of `trace`, so you can capture on one machine and
analyze on another.

---

## Commands

| Command | Description |
|---|---|
| `install` | Install the full networking toolkit. |
| `check` | Inventory which tools are installed. |
| `probe <host> [port]` | DNS + reachability + connectivity tests, now. |
| `trace <host> [port]` | Capture + analyze (default 180s, Ctrl-C to stop early). |
| `capture <host> [port]` | Record a `.pcap` only. |
| `analyze <file.pcap> [host] [port]` | Analyze an existing capture, offline. |
| `run <host> [port]` | probe + trace + unified report. |
| `interactive` (aliases: `int`, `i`, `menu`) | Guided menu: pick a connection, choose probe/trace/run. |
| `suggest [host] [port]` | Print copy-paste commands for a target (no host = generic cheatsheet). |
| `help` · `version` | Usage and version. |

Port defaults to `443`. A bare `nwutils <host> [port]` is shorthand for `nwutils run <host> [port]`.

### Options

| Option | Description |
|---|---|
| `-d, --duration <sec>` | Capture length for `capture` / `trace` / `run` (default: 180). |
| `--ascii` | Plain-ASCII UI (no box-drawing characters). |
| `-h, --help` · `-v, --version` | Help / version. |

Set `NWUTILS_LOG_DIR` to control where logs, captures, and the HTML report are written. Otherwise
the script picks the first writable path among `/home/Logfiles`, `/Appuserlogs`,
`$TMPDIR/nwutils`, and `./nwutils-out`.

---

## Reachability vs. connectivity

- **Reachability** answers "can a packet reach the host, and is the port open, closed, or
  filtered?" — tested with `nc` and `nmap --reason`.
- **Connectivity** answers "can I complete TLS and get a usable application response?" — tested
  end-to-end with `curl` (real HTTP status, including for HTTPS) plus packet-level RTT,
  retransmits, and resets.

---

## What the analysis reports

From the capture, `analyze` produces a per-stream TCP table plus a health report and a
plain-English summary that call out:

- DNS errors (NXDOMAIN, SERVFAIL, slow responses)
- Reachability (open / filtered / refused; SYN with no SYN-ACK)
- Connection establishment failures, rejects, and timeouts
- Packet loss (retransmissions, lost segments, duplicate ACKs)
- Latency (average and max RTT)
- Connection resets and **who closed first, the client or the server**

---

## Usage examples

```bash
# Everything in one shot
nwutils run api.example.com 443

# Live tests only (no capture, no root needed)
nwutils probe api.example.com 443

# Trace for 3 minutes (Ctrl-C to stop early), then analyze
nwutils trace api.example.com 443

# Capture now, analyze later (even on another machine)
nwutils capture api.example.com 443 -d 300
nwutils analyze /home/Logfiles/nwutils_api_example_com_443_*.pcap api.example.com 443

# Guided menu
nwutils interactive

# Install tools, then troubleshoot by hand
nwutils install
nwutils suggest api.example.com 443
```

---

## Requirements

- A Bash-capable Linux distro (Ubuntu, Debian, RHEL, CBL-Mariner / Azure Linux, Alpine).
- Root or sudo for **tool installation** and **packet capture** (`tcpdump`). `probe` and
  `analyze` do not need root.
- `tshark` is required for capture analysis. If it is missing, the `.pcap` is still saved for
  manual review.
- Internet access is only needed to install tools.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/azureossd/networking-troubleshooting-utility/refs/heads/main/nwutils_install.sh | bash
```

This installs `nwutils` to `/usr/local/bin/nwutils`. Then run:

```bash
nwutils help
```
