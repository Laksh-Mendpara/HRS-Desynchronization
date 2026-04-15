# Mitigation

## Overview

The `mitigation/` directory contains hardened drop-in replacements for the vulnerable Nginx and Varnish configurations. The hardened backend fix is applied to `backend/main.go` directly.

---

## Included Mitigation Files

| File | Replaces |
|---|---|
| `mitigation/nginx.conf` | `nginx/nginx.conf` |
| `mitigation/default.vcl` | `varnish/default.vcl` |

---

## Apply the Mitigation

```bash
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

---

## Verify the Mitigation is Active

### Method 1 — Run the exploit script

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=mit1"
```

Expected Phase 1 result:

```
HTTP/1.1 400 Bad Request
...
Ambiguous request rejected – dual length headers
```

The exploit is blocked at the edge. Phases 2 and 3 show the legitimate `application/javascript` response — the cache is not poisoned.

### Method 2 — Manual curl

```bash
curl -i \
  -X POST \
  -H "Transfer_Encoding: chunked" \
  -H "Content-Length: 153" \
  --data-binary $'6\r\nCLTE=1\r\n0\r\n\r\n' \
  http://localhost/reflect
```

Expected:

```
HTTP/1.1 400 Bad Request
Content-Type: text/plain

Ambiguous request rejected – dual length headers
```

---

## Mitigation Strategy — What Each Control Does

### 1. Nginx: expose underscore headers (`underscores_in_headers on`)

Without this directive, Nginx silently drops `Transfer_Encoding` (underscore) **before** the map logic runs — so the dual-header check never fires. This directive is counterintuitively **required** for the mitigation to actually detect the attack.

```nginx
underscores_in_headers on;
```

### 2. Nginx: detect and reject dual-length requests (400)

```nginx
map "$http_transfer_encoding:$http_content_length" $reject_dual_header {
    default          0;
    "~^[^:]+:[^:].+" 1;   # both headers present and non-empty
}

if ($reject_dual_header) {
    return 400 "Ambiguous request rejected – dual length headers\n";
}
```

HTTP Request Smuggling requires ambiguity between `Content-Length` and `Transfer-Encoding`. Rejecting any request that carries both eliminates the prerequisite for CL.TE / TE.CL desync attacks at the edge, before the payload reaches Varnish or the backend.

### 3. Nginx: strip Transfer-Encoding before forwarding

```nginx
proxy_set_header Transfer-Encoding "";
```

Even if the 400 block is somehow bypassed, stripping `Transfer-Encoding` ensures the downstream Varnish and backend never see a chunked framing header, closing the desync vector.

### 4. Nginx: buffer the full request

```nginx
proxy_request_buffering on;
```

Without buffering, Nginx streams request bytes to Varnish as they arrive. With buffering, Nginx fully reads and validates the complete request before forwarding — preventing partial-write races that can leave smuggled bytes in the upstream socket.

### 5. Nginx: force Connection: close to backend

```nginx
proxy_set_header Connection "close";
```

This ensures each Nginx → Varnish hop uses a separate connection, preventing connection-level header injection via hop-by-hop manipulation.

### 6. Varnish: reject dual-length at cache edge

```vcl
if (req.http.Transfer-Encoding && req.http.Content-Length) {
    return(synth(400, "Ambiguous request rejected"));
}
```

A second rejection layer at the Varnish level. Even if Nginx's block is bypassed, Varnish catches the conflicting framing headers before they reach the backend.

### 7. Varnish: strip TE before backend fetch

```vcl
unset bereq.http.Transfer-Encoding;
```

Prevents the Go backend from ever seeing a `Transfer-Encoding` header on Varnish→backend requests, eliminating any possibility of backend-level desync.

### 8. Varnish: force Connection: close on backend

```vcl
set bereq.http.Connection = "close";
```

Closes the Varnish → backend connection after each request. Without keep-alive, there is no persistent socket buffer for smuggled bytes to survive in between requests.

### 9. Varnish: never cache 5xx error responses

```vcl
if (beresp.status >= 500) {
    set beresp.uncacheable = true;
    set beresp.ttl = 1s;
    return(deliver);
}
```

Prevents error pages (which may contain attacker-influenced content from a partially successful smuggling attempt) from being cached and served to other users.

---

## Restore the Vulnerable Configuration

```bash
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

---

## Why These Mitigations Work Together

HTTP Request Smuggling exploits disagreement about message boundaries between layers. The defenses create **multiple redundant checkpoints**:

```
Request arrives
       │
       ▼
  Nginx (edge)
  ─ underscores_in_headers on  →  sees Transfer_Encoding header
  ─ map + if block             →  detects TE + CL simultaneously → 400
  ─ proxy_request_buffering    →  fully validates before forwarding
  ─ strip Transfer-Encoding    →  downstream never sees TE
       │ (only clean requests pass)
       ▼
  Varnish (cache)
  ─ vcl_recv dual-length check →  second rejection layer
  ─ unset TE in vcl_recv       →  ensures backend never sees TE
  ─ Connection: close          →  no persistent socket = no smuggled bytes
  ─ no error caching           →  poisoned errors can't spread
       │
       ▼
  Go Backend
  ─ receives clean, Content-Length-only request
  ─ no desync possible
```
