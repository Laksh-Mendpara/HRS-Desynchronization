"""Gunicorn entry-point for the Flask application.

Worker configuration is set here so that Gunicorn maintains persistent
(keep-alive) connections to Nginx.  This is critical for the PoC: it ensures
that a smuggled request prefix written into the socket buffer by the first
request is still present when the next (victim) request arrives.
"""

from app import app  # noqa: F401 - re-exported for Gunicorn

bind = "0.0.0.0:8000"

# sync workers + keepalive means the same socket is reused across requests,
# leaving smuggled bytes in the buffer between turns.
worker_class = "sync"
workers = 1
keepalive = 5

# Disable the timeout so long-lived connections are not forcibly closed.
timeout = 120
