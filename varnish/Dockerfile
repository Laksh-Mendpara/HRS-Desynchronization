# Cache-layer image: Varnish 4.1 from Alpine 3.5.
# We deliberately use Alpine 3.5 because it provides Varnish 4.1.
# Modern Varnish (6.0+) includes a strict HTTP/1.1 parser that immediately
# rejects requests containing both Content-Length and Transfer-Encoding headers.
# Varnish 4.1 is more lenient and forwards these headers, which is
# required to demonstrate the CL.TE desync vulnerability against Gunicorn.
FROM alpine:3.5

# Install Varnish 4.1 from the Alpine 3.5 main repository.
# We explicitly use an IP-accessible or specific mirror because old CDNs are dead.
RUN echo "http://dl-4.alpinelinux.org/alpine/v3.5/main" > /etc/apk/repositories && \
    apk update && \
    apk add --no-cache varnish

# Copy the VCL (Varnish Configuration Language) file.
COPY default.vcl /etc/varnish/default.vcl

EXPOSE 6081

# Run Varnish in foreground mode.
CMD ["varnishd", \
     "-F", \
     "-f", "/etc/varnish/default.vcl", \
     "-a", "0.0.0.0:6081", \
     "-s", "malloc,64m", \
     "-n", "/tmp/varnish_work"]
