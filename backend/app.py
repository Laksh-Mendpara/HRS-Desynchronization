"""Flask backend application for the HRS Desynchronization lab.

This application acts as the backend-origin in a three-tier proxy stack.
It is intentionally configured with security-critical monkey-patches to
demonstrate HTTP Request Smuggling (HRS) vulnerabilities in modern setups.
"""

from flask import Flask, Response, request
import sys

# ── Gunicorn Monkey-Patching for CL.TE Desync ───────────────────────────────
# These patches are essential for the HRS lab. They create the parsing
# discrepancy between the frontend (Varnish) and backend (Gunicorn) and
# enforce connection persistence.
try:
    import gunicorn.http.parser as p
    from gunicorn.http.message import Request
    from gunicorn.http.body import Body, LengthReader, EOFReader
    from gunicorn.http.wsgi import Response as GResponse
    from gunicorn.http.parser import Parser, SocketUnreader

    # 1. Connection Persistence (Keep-Alive)
    # Gunicorn's default behavior often forces connection closure.
    # We neutralize these flags to ensure the smuggled bytes stay in the pipe.
    GResponse.force_close = lambda self: None

    _orig_default_headers = GResponse.default_headers
    def v_headers(self):
        headers = _orig_default_headers(self)
        clean = [h for h in headers if "Connection: close" not in h]
        if not any("Connection:" in h for h in clean):
            clean.append("Connection: keep-alive")
        return clean
    GResponse.default_headers = v_headers

    # 2. Skip-and-Smuggle (Desync Alignment)
    # This patch intercepts the body-reader initialization. When an attack
    # request with 'Transfer-Encoding' is detected, it manually consumes the
    # transition payload (16 bytes) and then tells Gunicorn the body is empty.
    # This aligns the parser to read the smuggled request immediately next.
    _orig_sbr = Request.set_body_reader
    def v_sbr(self):
        is_chunked = False
        for (name, value) in self.headers:
            if name.upper() in ("TRANSFER-ENCODING", "TRANSFER_ENCODING"):
                is_chunked = True
                break
        
        if is_chunked:
            # Consume the 16-byte residue from the chunked transition body
            # (e.g., "6\r\nCLTE=1\r\n0\r\n\r\n")
            self.unreader.read(16)
            # Set a 0-byte body so the parser moves instantly to the smuggled request
            self.body = Body(LengthReader(self.unreader, 0))
        else:
            _orig_sbr(self)
    Request.set_body_reader = v_sbr

    # 3. Buffer Persistence
    # Prevent Gunicorn from clearing the socket buffer between requests.
    SocketUnreader.release = lambda self: None

    sys.stderr.write("DEBUG: HRS Exploit Stabilisation Patches Applied Successfully\n")
    sys.stderr.flush()
except Exception as e:
    sys.stderr.write(f"CRITICAL: Failed to apply HRS patches: {e}\n")
    sys.stderr.flush()

app = Flask(__name__)

# ── Routes ──────────────────────────────────────────────────────────────────

@app.route("/", methods=["GET", "POST"])
def index():
    """Simple homepage for connectivity checks."""
    return Response("HRS Lab Backend: Online\n", status=200, mimetype="text/plain")

@app.route("/js/app.js")
def js_app():
    """The cache-poisoning target asset.
    In a successful attack, this route is bypassed for the poisoned request,
    and Varnish instead caches the output of the /reflect endpoint.
    """
    return Response("// Legitimate application script\nconsole.log('App loaded.');\n", 
                    status=200, mimetype="application/javascript")

@app.route("/reflect", methods=["GET", "POST"])
def reflect():
    """Reflection endpoint used for XSS injection during smuggling.
    Echoes the 'q' parameter unsanitised into the response body.
    """
    q = request.args.get("q", "")
    body = f"<html><body>{q}</body></html>\n"
    return Response(body, status=200, mimetype="text/html")

@app.route("/admin")
def admin():
    """Simulated sensitive area for smuggling bypass demos."""
    return Response("Sensitive Admin Console\n", status=200, mimetype="text/plain")
