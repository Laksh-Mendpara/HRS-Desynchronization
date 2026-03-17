FROM python:3.12-alpine

WORKDIR /app

# Install dependencies first for layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py wsgi.py ./

# Start Gunicorn using the configuration in wsgi.py.
CMD ["gunicorn", "--config", "wsgi.py", "app:app"]
