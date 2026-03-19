# Architecture

## Stack Overview

The lab is composed of three runtime layers:

1. `frontend-proxy` using Nginx
2. `cache-layer` using Varnish
3. `backend-origin` using Gunicorn and Flask

Traffic path:

`attacker -> nginx stream proxy -> varnish -> gunicorn/flask`

## Role Of Each Layer

### Nginx

Nginx is configured as a raw TCP proxy using the `stream {}` module.

Effect:

- it listens on port `80`
- it forwards traffic to Varnish on port `6081`
- it does not perform normal HTTP-layer validation

### Varnish

Varnish acts as the caching layer.

Effect:

- it decides whether to cache or pass a request
- it caches `.js` and `.css` responses
- it reuses backend connections in a way that helps preserve the attack state

### Gunicorn / Flask

The backend origin serves the application responses.

Effect:

- `/` returns a simple response
- `/js/app.js` returns the legitimate JavaScript asset
- `/reflect?q=` reflects attacker-controlled input
- custom patching makes the backend suitable for this desynchronization lab

## Why This Layout Matters

The core attack depends on different components treating the same byte stream differently.

- the frontend path preserves the attacker-controlled bytes
- the cache layer later asks for a cacheable object
- the backend interprets leftover bytes as the start of a different request

That mismatch lets the response for `/reflect?q=<payload>` become stored under the cache key for `/js/app.js`.

## Cache Target

The main target is:

- `/js/app.js`

For repeatable testing, a better target is often:

- `/js/app.js?cb=<unique>`

The query string creates a fresh cache key and avoids collisions with previously cached content.

## Files That Define The Architecture

- `docker-compose.yml`
- `nginx/nginx.conf`
- `varnish/default.vcl`
- `backend/app.py`
- `backend/wsgi.py`
