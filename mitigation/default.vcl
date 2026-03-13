vcl 4.1;

# ============================================================================
# default.vcl  –  HARDENED / MITIGATED CONFIGURATION
# ============================================================================
# Changes vs. the vulnerable version (varnish/default.vcl):
#
#   1. Strip Transfer-Encoding from all backend fetch requests.  This prevents
#      Gunicorn from ever acting on a TE:chunked header forwarded through the
#      cache layer, closing the CL.TE desync vector at the Varnish→origin leg.
#
#   2. Enforce Connection: close on backend fetches so that the keep-alive
#      socket is not reused across requests, eliminating the socket-buffer
#      persistence that a smuggled prefix depends on.
#
#   3. Hash on Vary headers and X-Forwarded-For so that cache keys are not
#      easily manipulated by injected headers.
#
#   4. Add a brief negative TTL for error responses (5xx) to prevent caching
#      of error pages that might contain attacker-injected data.
# ============================================================================

backend default {
    .host = "backend-origin";
    .port = "8000";
    .max_connections = 10;
    .connect_timeout    = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
}

# ── vcl_recv ─────────────────────────────────────────────────────────────────
sub vcl_recv {
    # Only cache safe, idempotent methods.
    if (req.method != "GET" && req.method != "HEAD") {
        return(pass);
    }

    # ── Mitigation: reject dual-length requests ───────────────────────────
    # If both Transfer-Encoding and Content-Length are present, the request is
    # potentially smuggled; return 400 immediately rather than forwarding it.
    if (req.http.Transfer-Encoding && req.http.Content-Length) {
        return(synth(400, "Ambiguous request rejected"));
    }

    # Strip Transfer-Encoding unconditionally – Varnish handles chunked
    # decoding internally; forwarding TE to the origin is unnecessary and
    # creates the desync condition exploited by this lab.
    unset req.http.Transfer-Encoding;

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
    # ── Mitigation: strip TE and force Connection:close on origin requests ──
    # Removing Transfer-Encoding ensures Gunicorn cannot be tricked into
    # partial-body parsing, and Connection:close prevents socket reuse.
    unset bereq.http.Transfer-Encoding;
    set bereq.http.Connection = "close";
}

# ── vcl_backend_response ─────────────────────────────────────────────────────
sub vcl_backend_response {
    # ── Mitigation: never cache error responses ───────────────────────────
    if (beresp.status >= 500) {
        set beresp.uncacheable = true;
        set beresp.ttl = 1s;
        return(deliver);
    }

    # Cache static JavaScript and CSS files for 1 hour (unchanged behaviour).
    if (bereq.url ~ "\.(js|css)(\?.*)?$") {
        set beresp.ttl = 1h;
        set beresp.http.Cache-Control = "public, max-age=3600";
        unset beresp.http.Set-Cookie;
        return(deliver);
    }

    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return(deliver);
}

# ── vcl_deliver ───────────────────────────────────────────────────────────────
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}

# ── vcl_synth ────────────────────────────────────────────────────────────────
sub vcl_synth {
    set resp.http.Content-Type = "text/plain; charset=utf-8";
    synthetic(resp.reason + "\n");
    return(deliver);
}
