# HRS-Desynchronization

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](docker-compose.yml)
[![Go](https://img.shields.io/badge/Go-1.22-00ADD8?logo=go)](backend/main.go)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python)](exploit/attack.py)

An advanced educational laboratory demonstrating **web cache poisoning via CL.TE HTTP Request Smuggling**. The stack is a realistic three-tier pipeline — Nginx → Varnish → a natively-vulnerable Go server — with integrated packet-level observability.

```
Attacker ──► Nginx (HTTP/1.1 proxy, port 80)
                │  underscores_in_headers on  ← forwards Transfer_Encoding unchanged
                ▼
            Varnish (cache-layer, port 6081)
                │  vcl 4.0  ·  caches .js/.css for 1 h
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
| Frontend proxy | `frontend-proxy` | `nginx:1.25.5` | HTTP/1.1 reverse proxy; `underscores_in_headers on` lets `Transfer_Encoding` pass through |
| Cache | `cache-layer` | Alpine 3.5 + Varnish 4.1.9 | VCL 4.0; caches `.js`/`.css` 1 h; keeps persistent connections to origin |
| Origin | `backend-origin` | Go 1.22 (scratch) | Custom TCP server; intentionally honours `Transfer_Encoding` and stops at chunked terminator |
| Observability | `network-sniffer` | `nicolaka/netshoot` | `tcpdump` in backend network namespace → `captures/smuggling_trace.pcap` |

### Why This Stack Creates the Vulnerability

1. **Nginx** uses `underscores_in_headers on`, so `Transfer_Encoding` (underscore) is forwarded alongside a normal `Content-Length`. It proxies as HTTP/1.1 with `Connection: keep-alive`.
2. **Varnish** sees both headers, passes the POST to origin (cache miss), and keeps the connection open.
3. **The Go backend** detects `Transfer_Encoding: chunked`, reads until `0\r\n\r\n`, and **stops** — leaving the smuggled prefix in the TCP socket buffer.
4. The attacker's follow-up trigger request causes Varnish to fetch `/js/app.js` from the backend, but the backend reads the smuggled `GET /reflect?q=<payload>` prefix first, returning the attacker's HTML.
5. Varnish **caches** that HTML response under the `/js/app.js` cache key.

---

## 📁 Repository Layout

```
HRS-Desynchronization/
├── backend/
│   ├── Dockerfile          # Multi-stage Go build → scratch image
│   └── main.go             # Natively-vulnerable TCP HTTP server (Go)
├── captures/               # Auto-generated .pcap files (git-ignored)
├── exploit/
│   └── attack.py           # 4-phase CL.TE cache-poisoning toolkit (Python)
├── mitigation/
│   ├── nginx.conf          # Hardened Nginx (rejects dual-length requests)
│   └── default.vcl         # Hardened Varnish VCL (strips TE, forces conn:close)
├── nginx/
│   └── nginx.conf          # Vulnerable Nginx config (underscores_in_headers on)
├── varnish/
│   └── default.vcl         # Vulnerable VCL 4.0 config
├── docs/                   # Detailed documentation
├── docker-compose.yml      # Full 4-container lab stack
└── pyproject.toml          # Python exploit dependencies (uv)
```

---

## ⚙️ Prerequisites

- **Docker** with the Compose v2 plugin (`docker compose`)
- **Python 3.10+** and [`uv`](https://github.com/astral-sh/uv)
- **Wireshark** (optional — for PCAP analysis)

Install exploit dependencies:

```bash
uv sync
source .venv/bin/activate
# Windows: .venv\Scripts\activate
```

---

## 🚀 Start the Lab

```bash
docker compose up --build -d
docker compose ps          # all 4 containers should show "Up"
curl -i http://localhost/  # sanity-check the stack
```

---

## ⚔️ Perform the Attack

The exploit script (`exploit/attack.py`) runs a **4-phase** attack:

| Phase | Action |
|---|---|
| 0 | Probe for HTTP/2 support (informational — reveals additional H2.CL surface if present) |
| 1 | Send the CL.TE smuggling `POST /reflect` request (plants smuggled GET prefix in socket buffer) |
| 2 | Send trigger `GET /js/app.js?cb=…` on the **same** keep-alive connection |
| 3 | Open a **new** connection and verify the cache is poisoned |

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

> **Tip:** Use a fresh `?cb=` value for each test run to avoid hitting a warm cache.

### Verify the Poisoning

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

Successful indicators:
- `X-Cache: HIT` — served from Varnish cache
- `Via: 1.1 varnish-v4` — confirms cache path
- Response body contains your raw HTML payload (e.g. `<script>alert('Cache Poisoned!')</script>`)
- `Content-Type: text/html` instead of `application/javascript`

---

## 🔎 Observability (PCAP / Wireshark)

Every time the stack runs, the `network-sniffer` container captures raw traffic between Varnish and the Go backend:

1. Open `captures/smuggling_trace.pcap` in Wireshark.
2. Right-click any HTTP packet → **Follow → TCP Stream**.
3. You will see the chunked terminator `0\r\n\r\n` immediately followed by the smuggled `GET /reflect?q=…` prefix sitting in the raw TCP buffer — proving the boundary dispute.

---

## 🛡️ Mitigation & Remediation

The `mitigation/` directory contains hardened drop-in replacements:

| File | Key Changes |
|---|---|
| `mitigation/nginx.conf` | Rejects dual-length requests (400); strips `Transfer-Encoding`; enables request buffering; forces `Connection: close` to backend |
| `mitigation/default.vcl` | VCL 4.0; rejects dual-length at cache edge; strips `Transfer-Encoding` before backend fetch; forces `Connection: close`; never caches 5xx responses |

Apply the mitigations:

```bash
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose up --build -d
```

Re-run the exploit. The ambiguous request will be rejected with `400 Bad Request` and the cache will stay clean.

---

## 📚 References

- [RFC 7230 § 3.3.3 — Message Body Length](https://datatracker.ietf.org/doc/html/rfc7230#section-3.3.3)
- [PortSwigger Web Security Academy — HTTP Request Smuggling](https://portswigger.net/web-security/request-smuggling)
- [PortSwigger — Web Cache Poisoning](https://portswigger.net/web-security/web-cache-poisoning)

---

## License

MIT. See [LICENSE](LICENSE).