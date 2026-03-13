vcl 4.1;

# ── Backend ──────────────────────────────────────────────────────────────────
backend default {
    .host = "backend-origin";
    .port = "8000";

    # Keep connections alive to the origin so that a smuggled prefix written
    # into the socket buffer by one request is still present when Varnish
    # reuses the connection for the next request.
    .max_connections = 10;
    .connect_timeout    = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
}

# ── vcl_recv ─────────────────────────────────────────────────────────────────
sub vcl_recv {
    # Only cache GET and HEAD requests; pass everything else.
    if (req.method != "GET" && req.method != "HEAD") {
        return(pass);
    }

    # ── Desync-enabling (deliberately lenient) ────────────────────────────
    # Do NOT strip Transfer-Encoding from requests forwarded to the backend.
    # This allows Gunicorn to act on TE:chunked while Nginx/Varnish relied on
    # Content-Length, creating the CL.TE desynchronization condition.
    return(hash);
}

# ── vcl_hash ─────────────────────────────────────────────────────────────────
sub vcl_hash {
    hash_data(req.url);
    hash_data(req.http.Host);
    return(lookup);
}

# ── vcl_backend_fetch ────────────────────────────────────────────────────────
sub vcl_backend_fetch {
    # Pass through Transfer-Encoding so Gunicorn sees the TE:chunked header
    # and applies chunked-body framing, stopping at the zero-length terminator
    # and leaving any smuggled prefix in the socket buffer.
    # The explicit presence check prevents Varnish from adding a default value;
    # the header is intentionally left unchanged (no unset) to preserve the
    # desync condition.
    if (bereq.http.Transfer-Encoding) {
        return;
    }
}

# ── vcl_backend_response ─────────────────────────────────────────────────────
sub vcl_backend_response {
    # Cache static JavaScript and CSS files for 1 hour.
    # This is the cache-poisoning target: a smuggled response will be stored
    # under the /js/app.js (or *.css) cache key.
    if (bereq.url ~ "\.(js|css)(\?.*)?$") {
        set beresp.ttl = 1h;
        set beresp.http.Cache-Control = "public, max-age=3600";
        unset beresp.http.Set-Cookie;
        return(deliver);
    }

    # Do not cache anything else.
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return(deliver);
}

# ── vcl_deliver ───────────────────────────────────────────────────────────────
sub vcl_deliver {
    # Expose whether the response was served from cache (useful for the lab).
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
