# ── Gunicorn Configuration ───────────────────────────────────────────────────
# gthread worker supports native Keep-Alive for HRS demo.
# ─────────────────────────────────────────────────────────────────────────────

bind = "0.0.0.0:8000"
workers = 1
worker_class = "gthread"
threads = 4
keepalive = 10
timeout = 120
accesslog = "-"
errorlog = "-"
