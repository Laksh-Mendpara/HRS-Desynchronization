# Architecture

## Stack Overview

The lab is composed of four Docker services defined in `docker-compose.yml`:

| Service | Technology | Exposed Port |
|---|---|---|
| `frontend-proxy` | Nginx 1.25.5 | `0.0.0.0:80` (public) |
| `cache-layer` | Varnish 4.1.9 (Alpine 3.5) | internal `6081` |
| `backend-origin` | Native Go TCP server (Go 1.22) | internal `8000` |
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

Nginx runs as an **HTTP/1.1 reverse proxy** (not a raw TCP stream proxy). It forward requests to Varnish on the internal Docker network.

**Vulnerable configuration** (`vulnerable_configs/nginx.conf`):

```nginx
http {
    underscores_in_headers on;   # THE VULNERABILITY — see below

    server {
        listen 80;
        location / {
            proxy_pass http://cache-layer:6081;
            proxy_http_version 1.1;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
        }
    }
}
```

- `underscores_in_headers on` — allows `Transfer_Encoding` (with an underscore) to pass through to Varnish. Without this, Nginx silently drops headers containing underscores before forwarding.
- HTTP/1.1 keep-alive is preserved end-to-end across all three tiers.
- Nginx is in **parse-and-forward** mode: it reads the HTTP headers but does not normalise or reject conflicting `Content-Length` + `Transfer_Encoding` combinations.

**Hardened configuration** (`mitigation/nginx.conf`) adds:
- `underscores_in_headers on` — still needed so the map can *see* the header before rejecting
- A `map` block that detects dual-length headers → `400 Bad Request`
- `proxy_set_header Transfer-Encoding ""` — strips TE before forwarding
- `proxy_request_buffering on` — reads the full request before forwarding
- `proxy_set_header Connection "close"` — prevents keep-alive reuse to Varnish

---

### Varnish (`varnish/default.vcl`)

Varnish 4.1.9 is the caching layer. The VCL declares `vcl 4.0` (required by Varnish 4.x; `vcl 4.1` is only valid on Varnish 5+).

**Vulnerable VCL** (`vulnerable_configs/default.vcl`) key behaviours:

- Caches responses whose URL ends in `.js` or `.css` for **1 hour**.
- Passes POST and non-GET requests directly to the backend without caching.
- **Maintains a persistent, single keep-alive connection** to the backend (`max_connections = 1`) — this is the condition that allows smuggled bytes to survive between requests.
- Does **not** strip or modify `Transfer-Encoding` before the backend fetch — it forwards the header intact.
- Adds `X-Cache: HIT / MISS` and `Via: 1.1 varnish-v4` diagnostic headers to responses.

**Hardened VCL** (`mitigation/default.vcl`) adds:
- Dual-length rejection in `vcl_recv` → `synth(400)`
- `unset req.http.Transfer-Encoding` in `vcl_recv`
- `unset bereq.http.Transfer-Encoding` + `set bereq.http.Connection = "close"` in `vcl_backend_fetch`
- `beresp.uncacheable = true` for all 5xx responses

---

### Native Go Backend (`backend/main.go`)

The backend is a **custom raw TCP HTTP server** written in Go — not a framework, not net/http. It listens on `0.0.0.0:8000` and handles each keep-alive connection in a dedicated goroutine.

**The engineered vulnerability:**

```go
// Detects both Transfer_Encoding (underscore) and Transfer-Encoding (hyphen)
if strings.Contains(upper, "TRANSFER_ENCODING: CHUNKED") ||
   strings.Contains(upper, "TRANSFER-ENCODING: CHUNKED") {
    isChunked = true
}

// THE VULNERABILITY: reads until 0\r\n\r\n, then STOPS.
// Content-Length is completely ignored. Smuggled bytes stay in socket buffer.
if isChunked {
    readChunkedBody(reader)
}
// ...loop continues → leftover bytes become the "next request"
```

- When `Transfer_Encoding: chunked` is detected, the backend reads only until `0\r\n\r\n`.
- The remaining bytes in the TCP socket buffer (the smuggled prefix) become the first bytes of the next request on the same connection.
- `Content-Length` is completely disregarded when TE is present.

**Endpoints:**

| Path | Behaviour |
|---|---|
| `/` | Returns plain text status message |
| `/js/app.js` | Returns a static JavaScript snippet (`// Legitimate application script`) |
| `/reflect?q=<value>` | URL-decodes `q` and reflects it verbatim as raw HTML in `<html><body>…</body></html>` — **no sanitisation** |

---

### Network Sniffer (`network-sniffer`)

A `tcpdump` sidecar that shares the backend container's **network namespace** (`network_mode: "service:backend-origin"`). It captures all traffic arriving on port 8000 and writes it to `captures/smuggling_trace.pcap`.

This lets you open the PCAP in Wireshark and see — at the raw TCP level — the chunked terminator `0\r\n\r\n` immediately followed by the smuggled `GET /reflect?q=…` bytes sitting unread in the socket buffer, proving the boundary dispute.

---

## Why This Layout Creates the Desynchronization

The attack depends on **three simultaneous conditions** all being true:

| Condition | Maintained by |
|---|---|
| `Transfer_Encoding` reaches the backend | `underscores_in_headers on` in Nginx; Varnish passes TE unchanged |
| Smuggled bytes persist between requests | Varnish keeps a single persistent connection (`max_connections = 1`); backend responds with `Connection: keep-alive` |
| Backend stops at chunked terminator | `readChunkedBody()` reads only to `0\r\n\r\n`, ignoring `Content-Length` |

When the attacker sends the trigger request, Varnish reuses the existing backend connection. The backend reads the smuggled prefix from the socket buffer instead of the real trigger, processes `/reflect?q=<payload>`, and returns attacker HTML. Varnish caches that response under the `/js/app.js` cache key.

---

## Cache Target

The recommended demonstration target path format:

```
/js/app.js?cb=<unique>
```

The query string creates a **fresh cache key**, avoiding collisions with any previously cached content. Each `?cb=` value is an independent Varnish cache entry. Using repeated values causes Varnish to serve the cached (legitimate) response before the exploit has a chance to poison it.

---

## Files That Define the Architecture

| File | Purpose |
|---|---|
| `docker-compose.yml` | Service definitions, networks, volumes |
| `nginx/nginx.conf` | Active Nginx config (link from `vulnerable_configs/` or `mitigation/`) |
| `varnish/default.vcl` | Active Varnish VCL |
| `vulnerable_configs/nginx.conf` | Reference vulnerable Nginx config |
| `vulnerable_configs/default.vcl` | Reference vulnerable Varnish VCL |
| `mitigation/nginx.conf` | Hardened Nginx config |
| `mitigation/default.vcl` | Hardened Varnish VCL |
| `backend/main.go` | Native Go vulnerable HTTP server |
| `backend/Dockerfile` | Multi-stage build → minimal scratch image |
