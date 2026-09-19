# TLS Assessment for sa_plugin_http_server (P2)

Date: 2026-09-19
Decision: **Do NOT implement native TLS in the plugin. Recommend reverse-proxy TLS termination.**

## Why native TLS exceeds the 2-day budget

Implementing TLS directly in this plugin requires:

1. **Certificate/private-key loading** — PEM parsing, key format validation
   (RSA/ECDSA), encrypted key support, file permission checks. New config
   surface: cert path, key path, chain handling, SNI.

2. **TLS engine integration** — The plugin uses raw `std.net.Stream` sockets
   with `std.http.Server`. Wrapping every read/write in a TLS record layer
   means either:
   - Porting a TLS implementation into the plugin (large), or
   - FFI to OpenSSL/mbedTLS (new native dependency, breaks the current
     dependency-free build; cross-platform story gets complicated).

3. **Handshake timeouts and error states** — The accept loop is poll-driven
   with time-bounded head parses. TLS handshakes are multi-round-trip and
   can stall; they need their own timeout state machine integrated with
   `pollAcceptEx`, `drainRecycled`, and the worker pool — without wedging
   the single accept loop (the exact class of bug P0 just fixed).

4. **Session lifecycle** — TLS session resumption, ticket rotation, clean
   close_notify shutdown vs the current keep-alive recycle path
   (`isPeerClosed`, `pushRecycled`). A half-closed TLS session recycled
   into the idle pool is a new source of wedge/RST bugs.

5. **Certificate rotation** — Hot-reload without dropping connections;
   interacts with `stop_serving` semantics.

6. **Thread-pool / keep-alive integration** — `serve_threaded` workers share
   the poll loop; TLS state per connection must be thread-safe across
   recycle. The wake-pipe and pool-sweep logic would need TLS-aware
   readiness (a TLS record can be "readable" while the socket poll says
   nothing, due to buffered decrypted bytes).

7. **Cross-platform validation** — Linux/Windows/macOS socket + TLS
   behavior differences, plus the sa plugin sandbox permission model
   (`sap.json` net permissions would need `https://` entries).

Each of items 3, 4, and 6 is a multi-day correctness risk on its own
(the P0 accept-loop wedge took a full day to diagnose). Combined, this
is comfortably over 2 days.

## Recommended: reverse-proxy TLS termination

Run Caddy or nginx in front of the plugin:

```
Internet --TLS--> Caddy/nginx (:443) --plain HTTP--> plugin (127.0.0.1:8080)
```

- The plugin already binds `127.0.0.1` by default; `sap.json` permits
  `http://0.0.0.0` for LAN deployments behind a proxy.
- Caddy gives automatic Let's Encrypt certificates with zero config;
  nginx gives full control. Both handle handshake timeouts, session
  resumption, rotation, and HTTP/2 — all outside the plugin.
- The plugin keeps its plain-HTTP accept loop, keep-alive pool, and
  thread pool exactly as benchmarked (P0/P1 numbers stand).
- `X-Forwarded-Proto` / `X-Forwarded-For` headers carry the original
  scheme/client IP; handlers that need them can read them via the
  existing header APIs (no plugin change required).

## What would change this decision

If a deployment cannot run a sidecar proxy (e.g. single-binary edge),
revisit with a dedicated TLS milestone: vendor a minimal TLS 1.3
implementation behind the existing `ConnState` abstraction, add
handshake timeout states to `pollAcceptEx`, and budget 1–2 weeks
including fuzzing the handshake/close_notify paths.
