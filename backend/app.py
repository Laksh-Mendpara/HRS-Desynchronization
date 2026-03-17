from flask import Flask, Response, request

app = Flask(__name__)


@app.route("/")
def index() -> Response:
    return Response(
        "Welcome to the public homepage.\n",
        status=200,
        mimetype="text/plain",
    )


@app.route("/js/app.js")
def js_app() -> Response:
    """Legitimate static JavaScript file – the cache-poisoning target."""
    js_content = (
        "// Legitimate application script\n"
        "console.log('App loaded successfully.');\n"
    )
    return Response(js_content, status=200, mimetype="application/javascript")


@app.route("/reflect")
def reflect() -> Response:
    """Reflection endpoint used for injecting the poisoned payload.

    The attacker smuggles a GET /reflect?q=<payload> request; the backend
    returns a response whose body contains the raw *q* parameter value.
    Varnish then mistakenly caches that response under the /js/app.js key.
    """
    q = request.args.get("q", "")
    body = f"<html><body>{q}</body></html>\n"
    return Response(body, status=200, mimetype="text/html")


@app.route("/admin")
def admin() -> Response:
    # In a real application this would be guarded by authentication.
    # Kept for backward compatibility with the original CL.TE PoC.
    return Response(
        "Sensitive Admin Data\n",
        status=200,
        mimetype="text/plain",
    )
