This document outlines the operational logic and technical specifications for the **HTTP Request Smuggling (CL.TE) & Cache Poisoning** environment.

## 🎯 Project Objective

To demonstrate a sophisticated **Web Cache Poisoning** attack by exploiting parsing discrepancies between an Edge Proxy (Nginx), a Caching Layer (Varnish), and an Origin Server (Gunicorn).

---

## 🏗️ System Architecture

The environment is containerized to simulate a real-world production stack where requests pass through multiple layers of abstraction.

| Component | Role | Logic |
| --- | --- | --- |
| **Nginx** | Frontend / Edge | Forwards requests via `proxy_pass`. Lenient on dual-header validation. |
| **Varnish** | Cache Layer | Caches static assets (`.js`, `.css`). The target for poisoning. |
| **Gunicorn/Flask** | Origin Server | Synchronous worker handles `Transfer-Encoding: chunked`. |
| **Exploit Script** | The Agent | Custom Python socket-level payload generator. |

---

## ⚡ Attack Mechanism: Theoretical Flow

The attack relies on a **Desynchronization** of the message stream.

1. **The Payload:** The agent sends a `POST` request containing both `Content-Length` (CL) and `Transfer-Encoding: chunked` (TE) headers.
2. **The Discrepancy:** * **Nginx/Varnish** uses **CL** to determine the message end.
* **Gunicorn** uses **TE** to determine the message end.


3. **The Smuggle:** A hidden `GET` request is placed inside the body of the `POST`. Because Gunicorn stops reading at the `0\r\n\r\n` (TE end-of-chunk), the hidden request remains in the backend's TCP buffer.
4. **The Poisoning:** The next legitimate request for a static file (e.g., `app.js`) is "glued" to the hidden request in the buffer. The backend responds to the hidden request instead, and Varnish caches that malicious response under the key for `app.js`.

---

## 🛠️ Implementation Details

### 1. Protocol Configuration

* **Keep-Alive:** Must be enabled across all tiers. If the TCP connection closes after one request, the "smuggled" bytes are lost.
* **Header Normalization:** Intentionally disabled in `nginx.conf` to prevent the proxy from "fixing" the malformed headers before they reach the backend.

### 2. The Exploit Agent (`attack.py`)

The agent must bypass high-level libraries (like `requests` or `httpx`) which sanitize outgoing packets.

* **Socket Level:** Uses `socket.sendall()` to transmit raw byte-strings.
* **Deterministic Timing:** Implements a slight delay between the smuggling payload and the trigger request to ensure the buffer is primed.

### 3. Verification & Forensics

To validate the attack, the agent monitors:

* **`varnishlog`**: To see the cache-miss/cache-hit cycle and the header mismatch.
* **`tcpdump`**: (On the Arch host) to observe the raw hex data moving between containers.

---

## 🛡️ Mitigation Strategy

The project demonstrates two primary defenses:

1. **Protocol Upgrade:** Moving to **HTTP/2** (binary framing) to eliminate text-based length ambiguity.
2. **Strict Validation:** Configuring Nginx to reject any request where `Transfer-Encoding` and `Content-Length` coexist (RFC 7230 compliance).
