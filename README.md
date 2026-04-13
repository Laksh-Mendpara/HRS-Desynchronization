# HRS-Desynchronization

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](docker-compose.yml)
[![Go](https://img.shields.io/badge/Go-1.22-00ADD8?logo=go)](backend/main.go)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python)](exploit/attack.py)

An advanced educational laboratory demonstrating cache poisoning via HTTP Request Smuggling (CL.TE). This project features a natively vulnerable Go-based backend and integrated packet-level observability to analyze raw socket desynchronization.

`attacker -> Nginx (Layer 7 Proxy) -> Varnish Cache -> Native Go Backend`

## 🏗️ Architecture & Desynchronization Pipeline

```text
  ┌─────────────┐   port 80    ┌───────────────────┐  :6081  ┌──────────────────┐  :8000  ┌──────────────────────┐
  │  Attacker   │─────────────▶│  Nginx            │────────▶│  Varnish         │────────▶│  Native Go Server    │
  │ attack.py   │   HTTP/1.1   │  Layer 7 Proxy    │         │  cache-layer     │         │  backend-origin      │
  └─────────────┘              │  Vulnerable Conf  │         │  caches .js/.css │         │  Engineered Desync   │
                               └───────────────────┘         └──────────────────┘         └──────────────────────┘
                                                                       │                             │
                                                                       ▼                             ▼
                                                             ┌───────────────────────────────────────────────┐
                                                             │   Wireshark / tcpdump (Packet Observability)  │
                                                             └───────────────────────────────────────────────┘




Key Engineering Upgrades
Realistic Proxy Misconfiguration: Unlike basic TCP pass-throughs, this Nginx proxy actively parses HTTP/1.1 but features a realistic administrative vulnerability (underscores_in_headers on;), allowing malformed framing to penetrate the network.

Native Systems Backend: The backend is a custom, lightweight HTTP server written in Go. Rather than relying on monkey-patched frameworks, it natively demonstrates socket parsing discrepancies by mishandling TCP buffers when encountering conflicting Content-Length and Transfer-Encoding headers.

Protocol Observability: The stack includes a tcpdump sidecar container that sniffs the Varnish-to-Go network namespace, automatically generating .pcap files for deep protocol analysis in Wireshark.






Repository Layout



HRS-Desynchronization/
├── backend/            # High-performance, natively vulnerable Go server
├── captures/           # Auto-generated .pcap files for Wireshark analysis
├── exploit/            # Python-based HTTP Request Smuggling toolkit
├── mitigation/         # Hardened configurations for remediation
├── nginx/              # Vulnerable Layer 7 reverse proxy configurations
├── varnish/            # Caching layer configurations
└── docker-compose.yml



Prerequisites
Docker with docker compose

Python 3.10+ and uv package manager

Wireshark (Optional, but highly recommended for PCAP analysis)

Install exploit dependencies and activate the virtual environment:


uv sync
source .venv/bin/activate 
# Note for Windows: .venv\Scripts\activate


Start The Lab
Launch the stack in detached mode:


docker compose up --build -d

curl -i http://localhost/

Perform The Attack
The exploit script performs a 3-phase attack:

Sends a POST /reflect with conflicting CL/TE headers, leaving a smuggled GET in the Go socket buffer.

Sends a trigger request for a cacheable asset (/js/app.js).

Verifies that Varnish has permanently cached the attacker's payload.

(Note for Windows users: Ensure you use double quotes " around the target path to prevent CMD parsing errors).


python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=demo1"


Verify the Poisoning Manually:

curl -i "http://localhost/js/app.js?cb=demo1"

You will see X-Cache: HIT and the attacker's HTML payload instead of the legitimate JavaScript.

🔎 Observability (Wireshark Analysis)
This lab captures the exact moment the socket desynchronizes. Every time the stack runs, traffic between the cache and the backend is recorded.

Navigate to the captures/ directory in your repository.

Open smuggling_trace.pcap in Wireshark.

Right-click any HTTP packet and select Follow > TCP Stream.

You will visibly see the chunked terminator (0\r\n\r\n), followed immediately by the smuggled HTTP prefix sitting in the raw TCP buffer, proving the boundary dispute between Varnish and the Go server.

🛡️ Mitigation & Remediation
This repository includes industry-standard, hardened configurations to patch the vulnerability.

Apply the defenses:

cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose up --build -d

Run the exploit again. The strict parsing rules will now reject the ambiguous framing, Nginx will sever the connection (returning a 502 Bad Gateway), and the cache will remain secure.

References
RFC 7230 Section 3.3.3

PortSwigger Web Security Academy: HTTP Request Smuggling

License
MIT. See LICENSE.