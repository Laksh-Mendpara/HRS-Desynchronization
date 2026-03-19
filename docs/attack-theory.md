# Attack Theory

## Attack Type

This project demonstrates web cache poisoning through HTTP request smuggling, specifically a CL.TE-style desynchronization idea adapted to this lab's custom behavior.

## Core Idea

The attacker sends one request that causes different parts of the stack to disagree about where the request ends.

When request boundaries become inconsistent:

- one component believes the request is finished
- another component leaves extra bytes unread
- those leftover bytes are treated as part of the next request

That is the desynchronization.

## Why The Attack Works

The exploit combines three ingredients:

### 1. A framing mismatch

The crafted request includes a body layout that makes the backend stop reading earlier than the upstream side expects.

### 2. A smuggled prefix

After the body terminator, the attacker places the beginning of another HTTP request:

`GET /reflect?q=<payload> HTTP/1.1`

This becomes the leftover prefix waiting in the backend connection buffer.

### 3. A cacheable trigger request

The attacker then sends a normal request for a cacheable path such as `/js/app.js`.

When the backend reads again, it consumes:

- the leftover smuggled prefix
- then part of the legitimate next request

As a result, the backend processes `/reflect?q=<payload>` while the cache layer still associates the response with `/js/app.js`.

## Poisoning Outcome

The cache stores the reflected attacker-controlled HTML under the cache key of a JavaScript file.

After that, later clients requesting the poisoned key receive:

- a cache `HIT`
- the attacker's reflected payload
- content that no longer matches the intended asset

## Why `/reflect` Is Used

The attack needs a backend endpoint that produces visible attacker-controlled output. `/reflect` is ideal in this lab because it echoes the supplied query value into the response body.

## Why Connection Reuse Matters

If the first request and second request do not share the relevant backend connection, the leftover bytes are lost and the attack fails.

That is why this lab depends on keep-alive behavior and backend connection persistence.

## Why Fresh Cache Keys Matter

If Varnish already has the target resource in cache, the trigger request may be answered immediately from cache instead of being forwarded to the backend.

When that happens:

- the smuggled prefix is never paired with the intended trigger
- the exploit appears to fail
- the target path stays legitimate

That is why a unique path like `/js/app.js?cb=demo1` is the recommended demonstration target.

## Lab-Specific Note

This repository uses a custom backend patch and a non-standard `Transfer_Encoding` header variant in the exploit. That detail is part of how this educational environment is stabilized and should not be treated as a statement about normal production behavior.
