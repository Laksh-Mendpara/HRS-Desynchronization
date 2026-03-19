# Assumptions

This lab works only because several assumptions are deliberately made true in the environment.

## Technical Assumptions

### 1. The frontend does not normalize HTTP requests

`nginx/nginx.conf` uses the `stream {}` module instead of the normal HTTP proxy module. That means Nginx behaves as a TCP forwarder and does not parse, reject, or clean suspicious HTTP headers before forwarding bytes to Varnish.

### 2. The cache layer forwards attacker-controlled framing

Varnish forwards the attacker request to the backend and does not strip the crafted transfer-related header used in this lab. That allows the backend and the upstream side of the chain to disagree about request boundaries.

### 3. Backend connections stay alive

The attack requires connection reuse between requests. If the backend connection closes after the first request, the smuggled bytes disappear and the attack fails.

### 4. The backend accepts the desync variant used by this project

This lab uses `Transfer_Encoding` with an underscore inside the exploit request. That behavior is specific to this project and its backend patching. During verification, replacing it with standard `Transfer-Encoding` caused the request to fail with `400 Bad Request`.

### 5. The target resource is cacheable

The attack is meaningful only because Varnish caches JavaScript and CSS responses for one hour. In this repo, `/js/app.js` is the intended poisoning target.

### 6. The target cache key is not already warm

If the target path is already cached, the trigger request may be served directly from cache and never reach the backend. That prevents the poisoned backend response from being stored under that key.

### 7. The reflection endpoint is attacker-controlled

The backend exposes `/reflect?q=` and reflects the `q` value without sanitization. That makes it possible to turn a successful desynchronization into a visible poisoned response.

## Operational Assumptions

### 1. The user is running the lab locally

The commands in this repository assume:

- Docker services are reachable on `localhost`
- the exposed frontend port is `80`
- the exploit script is launched from the repository root

### 2. The user has permission to run this project

This repository is intended for educational use on a controlled environment only.

### 3. The lab may become desynchronized between tests

If a test is interrupted at the wrong time, the backend connection state can remain confusing. Restarting the services is the safest way to return to a clean state.

## Practical Takeaway

This project is not modeling a generic web stack. It is a deliberately unstable and specially prepared demonstration environment. The exploit succeeds because the stack is designed to preserve exactly the request-boundary confusion that secure systems try to eliminate.
