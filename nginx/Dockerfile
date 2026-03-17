# Frontend-proxy image: Nginx 1.25 Alpine.
# This container sits at the edge (port 80) and forwards all traffic to the
# Varnish cache-layer.  It is configured to be deliberately lenient – it
# forwards both Content-Length and Transfer-Encoding without normalization,
# enabling the CL.TE desynchronization attack.
FROM nginx:1.25-alpine

# Replace the default Nginx configuration with our desync-enabling version.
COPY nginx.conf /etc/nginx/nginx.conf
