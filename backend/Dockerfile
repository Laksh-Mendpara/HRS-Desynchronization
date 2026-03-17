# Backend-origin image: Python 3.12 Alpine + Flask + Gunicorn.
# This container runs the vulnerable WSGI application that trusts
# Transfer-Encoding:chunked over Content-Length, enabling the CL.TE desync.
FROM python:3.12-alpine

WORKDIR /app

# Install Python dependencies first for Docker layer-caching efficiency.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code and Gunicorn configuration.
COPY app.py wsgi.py ./

# Start Gunicorn with the settings defined in wsgi.py.
# Key settings: sync workers, keepalive=5, workers=1 – all required
# for the smuggled prefix to persist in the socket buffer.
CMD ["gunicorn", "--config", "wsgi.py", "app:app"]
