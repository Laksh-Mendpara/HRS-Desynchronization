# Architecture

## Stack Overview

The lab is composed of four Docker services defined in `docker-compose.yml`:

| Service | Technology | Exposed Port |
|---|---|---|
| `frontend-proxy` | Nginx 1.25.5 | `0.0.0.0:80` |
| `cache-layer` | Varnish 4.1.9 (Alpine 3.5) | internal `6081` |
| `backend-origin` | Native Go TCP server | internal `8000` |
| `network-sniffer` | nicolaka/netshoot (`tcpdump`) | — (shares backend network namespace) |

Traffic path:

```
Attacker → Nginx (:80) → Varnish (:6081) → Go Backend (:8000)
                                                    ↑
                                            tcpdump sidecar
                                         (writes smuggling_trace.pcap)
```

---

## Role of Each Layer

### Nginx (`nginx/nginx.conf`)

Nginx runs in **HTTP proxy mode** (not TCP stream mode). This is the current architecture after moving away from the older `stream {}` pass-through approach.

Key configuration:

```nginx
underscores_in_headers on;   # THE VULNERABILITY
proxy_http_version 1.1;
proxy_set_header Connection "keep-alive";
proxy_pass http://cache-layer:6081;
```

- `underscores_in_headers on` allows the `Transfer_Encoding` header (with an underscore) to pass through without being dropped or rejected.
- HTTP/1.1 keep-alive is preserved end-to-end.
- Nginx **does** parse HTTP but does not normalise or reject conflicting `Content-Length` + `Transfer_Encoding` combinations in this vulnerable configuration.

### Varnish (`varnish/default.vcl`)

Varnish 4.1.9 acts as the caching layer. The VCL declares `vcl 4.0` (as required by this version — `vcl 4.1` is not supported until Varnish 5+).

Key behaviours:

- Caches responses whose URL ends in `.js` or `.css` for **1 hour** (`TTL: 1h`).
- Passes POST/non-GET requests directly to the backend (no caching).
- Maintains **persistent keep-alive connections** to the backend — this is the condition that allows the smuggled prefix to survive into the next request.
- Adds `X-Cache: HIT` or `X-Cache: MISS` and `Via: 1.1 varnish-v4` to responses.

### Native Go Backend (`backend/main.go`)

The backend is a **custom TCP HTTP server** written in Go — not a framework or Gunicorn/Flask. It listens on `0.0.0.0:8000` and handles keep-alive connections in a goroutine per connection.

**The engineered vulnerability:**

```go
// Detects Transfer_Encoding: chunked (underscore variant or hyphen)
if strings.Contains(strings.ToUpper(headerLine), "TRANSFER_ENCODING: CHUNKED") ||
   strings.Contains(strings.ToUpper(headerLine), "TRANSFER-ENCODING: CHUNKED") {
    isChunked = true
}

// If chunked: read until 0\r\n\r\n and STOP — ignores Content-Length.
// Smuggled bytes remain in the socket buffer.
if isChunked {
    readChunkedBody(reader)
}
```

- `Content-Length` is **completely ignored** when `Transfer_Encoding` is present.
- After reading the chunked body, the connection loop continues — the leftover smuggled bytes become the start of the "next request".

Endpoints:

| Path | Behaviour |
|---|---|
| `/` | Returns plain text status |
| `/js/app.js` | Returns a static JavaScript snippet |
| `/reflect?q=<value>` | URL-decodes `q` and reflects it as raw HTML in `<html><body>…</body></html>` |

### Network Sniffer (`network-sniffer`)

A `tcpdump` sidecar that shares the backend container's network namespace (`network_mode: "service:backend-origin"`). It captures all traffic on port 8000 and writes it to `captures/smuggling_trace.pcap`.

---

## Why This Layout Creates the Desynchronization

The attack depends on **three simultaneous conditions** all being true:

1. **Nginx forwards `Transfer_Encoding`** (underscore) because `underscores_in_headers on` prevents it from stripping or rejecting the non-standard header.
2. **Varnish keeps the backend connection alive** between requests, so bytes left over from request N become input for request N+1.
3. **The Go backend stops reading at `0\r\n\r\n`**, leaving the attacker's smuggled `GET /reflect?q=<payload>` prefix sitting in the socket buffer.

When the attacker's trigger request arrives, Varnish forwards it to the backend. The backend reads the smuggled prefix first, processes `/reflect?q=<payload>`, and returns the attacker's HTML. Varnish caches that response under the `/js/app.js` cache key.

---

## Cache Target

The recommended demonstration target:

```
/js/app.js?cb=<unique>
```

The query string creates a **fresh cache key**, avoiding collisions with previously cached content. Each `?cb=` value is its own independent Varnish cache entry.

---

## Files That Define the Architecture

| File | Purpose |
|---|---|
| `docker-compose.yml` | Service definitions, network, volumes |
| `nginx/nginx.conf` | Vulnerable Nginx config |
| `varnish/default.vcl` | Vulnerable VCL 4.0 config |
| `backend/main.go` | Native Go vulnerable HTTP server |
| `backend/Dockerfile` | Multi-stage build → scratch image |
