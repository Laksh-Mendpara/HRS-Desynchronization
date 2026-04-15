vcl 4.0;

# ===========================================================================
# default.vcl – VULNERABLE (desync-enabling) Varnish configuration
# ===========================================================================
# This VCL is intentionally permissive.  It:
#   • Forwards Transfer-Encoding from Nginx to Gunicorn without stripping it.
#   • Keeps persistent connections to the backend, allowing smuggled bytes in
#     the TCP socket buffer to survive between requests.
#   • Caches .js and .css responses for 1 hour – so a single poisoned
#     response is served to every subsequent visitor.
#
# See mitigation/default.vcl for the hardened version.
# ===========================================================================

# ── Backend (Gunicorn/Flask origin) ──────────────────────────────────────────
backend default {
    .host = "backend-origin";       # Docker Compose service name
    .port = "8000";                 # Gunicorn listen port

    # Strict persistence settings for HRS
    .max_connections        = 1;    # Force a single dedicated connection to origin
    .connect_timeout        = 10s;
    .first_byte_timeout     = 300s;
    .between_bytes_timeout  = 20s;
}

# ── vcl_recv ─────────────────────────────────────────────────────────────────
# Runs on every incoming client request.  We only cache GET/HEAD; anything
# else (including the attacker's initial POST) is passed straight through to
# the backend without caching.
sub vcl_recv {
    # Always 'pass' /reflect to ensure the POST body (the smuggled payload) 
    # is forwarded intact. Hashing a POST converts it to a GET and 
    # strips the body in many Varnish versions.
    if (req.url == "/reflect") {
        return(pass);
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return(pass);
    }

    # ── Desync-enabling (deliberately lenient) ────────────────────────────
    # We do NOT strip or reject Transfer-Encoding here.  This allows
    # the TE:chunked header to reach Gunicorn, creating the CL.TE
    # parsing discrepancy.
    return(hash);
}

# ── vcl_hash ─────────────────────────────────────────────────────────────────
# Determines the cache key.  The attacker exploits the fact that the cache
# key is derived from req.url (/js/app.js) while the backend actually
# processes a different URL (/reflect?q=…) due to the desync.
sub vcl_hash {
    hash_data(req.url);
    hash_data(req.http.Host);
    return(lookup);
}

# ── vcl_backend_fetch ────────────────────────────────────────────────────────
# Runs when Varnish fetches a resource from the backend (cache miss).
# The Transfer-Encoding header is intentionally left intact so Gunicorn
# applies chunked-body framing and stops at the zero-length terminator,
# leaving the smuggled prefix in the socket buffer.
sub vcl_backend_fetch {
    if (bereq.http.Transfer-Encoding) {
        # Header present – do not modify it; continue to fetch normally.
        return(fetch);
    }
}

# ── vcl_backend_response ────────────────────────────────────────────────────
# Controls caching policy for backend responses.  Static assets (.js, .css)
# are cached for 1 hour – this is the cache-poisoning target.
sub vcl_backend_response {
    # Cache static JavaScript and CSS files for 1 hour.
    # A smuggled response will be stored under the /js/app.js cache key.
    if (bereq.url ~ "\.(js|css)(\?.*)?$") {
        set beresp.ttl = 1h;
        set beresp.http.Cache-Control = "public, max-age=3600";
        unset beresp.http.Set-Cookie;   # Remove cookies so response is cacheable.
        return(deliver);
    }

    # Everything else is marked uncacheable.
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return(deliver);
}

# ── vcl_deliver ──────────────────────────────────────────────────────────────
# Runs just before sending the response to the client.  The X-Cache header
# makes it easy to tell whether the response was served from cache (HIT) or
# freshly fetched from the backend (MISS).
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
