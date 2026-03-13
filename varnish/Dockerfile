FROM alpine:3.19

# Install Varnish from Alpine packages.
RUN apk add --no-cache varnish

# Copy the VCL configuration.
COPY default.vcl /etc/varnish/default.vcl

EXPOSE 6081

# Run Varnish in foreground mode.
# -a  : listen address and port
# -f  : VCL configuration file
# -s  : storage backend (in-memory, 64 MB)
# -n  : working directory (must be writable)
CMD ["varnishd", \
     "-F", \
     "-f", "/etc/varnish/default.vcl", \
     "-a", "0.0.0.0:6081", \
     "-s", "malloc,64m", \
     "-n", "/tmp/varnish_work"]
