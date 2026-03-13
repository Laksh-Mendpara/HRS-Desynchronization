from flask import Flask, Response

app = Flask(__name__)


@app.route("/")
def index() -> Response:
    return Response(
        "Welcome to the public homepage.\n",
        status=200,
        mimetype="text/plain",
    )


@app.route("/admin")
def admin() -> Response:
    # In a real application this would be guarded by authentication.
    # The frontend (Nginx) blocks direct access to /admin with a 403, but the
    # smuggling exploit bypasses that restriction and reaches this handler.
    return Response(
        "Sensitive Admin Data\n",
        status=200,
        mimetype="text/plain",
    )
