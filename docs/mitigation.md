# Mitigation

## Included Mitigation Files

This repository includes hardened configurations in:

- `mitigation/nginx.conf`
- `mitigation/default.vcl`

## Apply The Mitigation

```bash
cp mitigation/nginx.conf nginx/nginx.conf
cp mitigation/default.vcl varnish/default.vcl
docker compose up --build -d
```

## Mitigation Strategy

The defenses focus on removing ambiguity and reducing the chance that one component interprets the request differently from another.

## Main Controls

### 1. Reject conflicting framing

Requests that carry both `Content-Length` and `Transfer-Encoding` should be rejected instead of forwarded.

### 2. Strip transfer-related ambiguity before forwarding

If an upstream component does not need to forward `Transfer-Encoding`, it should normalize or remove it before passing the request deeper into the stack.

### 3. Reduce risky connection reuse

Closing or isolating backend connections can stop leftover bytes from surviving into the next request.

### 4. Avoid caching attacker-influenced responses under shared keys

Cache policy should be conservative for dynamic or reflective responses.

## Why These Mitigations Help

HTTP request smuggling relies on disagreement about message boundaries. The simplest way to stop the attack is to make every layer agree on one validated request shape before forwarding anything.

## Practical Advice For This Repo

After applying the mitigation files:

1. rebuild the containers
2. rerun the exploit
3. confirm the poisoning no longer succeeds

Expected outcome:

- the crafted request is rejected, normalized, or neutralized
- the target path returns the legitimate JavaScript response
- the cache is not poisoned with reflected HTML
