# oidc-rproxy
Apache httpd configured as a reverse proxy.  It protects the upstream service using an OIDC provider like Azure AD.

This is packaged as a Docker container and it is available here https://hub.docker.com/r/richardjkendall/oidc-rproxy

## Images and tags

```
richardjkendall/oidc-rproxy:2026-08-30    <- current
richardjkendall/oidc-rproxy:latest        <- moves; points at the same build today
```

**Pin a dated tag.** `latest` moves, and something pulling it will change
underneath itself with no rollout and no record of which build it got. That is
not hypothetical here: `latest` served a **2021-01-30** build for five years
while this README described 2026 behaviour, because every consumer pulled it
untagged and nothing ever republished it. It was moved forward on 2026-08-30,
once nothing was pinned to it.

Build with `./build.sh` — plan by default, `--execute`, `--test`, `--push`.
`--test` runs the image against a real discovery document and asserts the state
cookie is `SameSite=None`, which is the regression guard described below.

## Upgrading to the 2026-08-30 build — one more behaviour change

`OIDCCookieSameSite Off` is now set, which makes the module emit
`SameSite=None` on its cookies rather than the `SameSite=Lax` that
mod_auth_openidc 2.4.15 defaults to.

**Without it, any IdP on a different registrable domain from the app breaks** —
and breaks in the least obvious way. `OIDCResponseMode form_post` means the IdP
returns by POSTing to `/redirect_uri`; browsers give a cookie with *no* SameSite
attribute a short "Lax+POST" grace, but give an explicit `Lax` none. So the
redirect *out* is correct, nothing logs an error at startup, and every login
fails at the callback with:

```
oidc_restore_proto_state: no "mod_auth_openidc_state_..." state cookie found:
check domain and samesite cookie settings
```

A gate fronted by `auth.example.com` protecting `app.example.com` never sees
this. One fronted by Google does.

Note the directive value: it accepts only `On` or `Off` — `None`, `Lax` and
`Strict` are rejected at startup and Apache refuses to start — and `Off` is what
produces `SameSite=None`.

**The cost:** the session cookie becomes `SameSite=None` too, so CSRF protection
for the proxied app is weaker than `Lax`. No weaker than the 2.3.3 behaviour it
replaces, but do not rely on this proxy for CSRF defence.

## Configuration
The container uses a number of environment variables to pass in configuration.  They are defined below:

|Variable|Purpose|Example|
|---|---|---|
|OIDC_PROVIDER_METADATA_URL|Metadata URL for the OIDC Provider|https://host.domain/.well-known/openid-configuration
|OIDC_PROVIDER_JWKS_URI|URI for the JSON Web Key Set for the OIDC provider|https://host.server/keys
|OIDC_CLIENT_ID|Client ID as configured for this application|n/a
|OIDC_CLIENT_SECRET|Client secret as configured for this application|n/a
|OIDC_CRYPTO_PASSPRHASE|Passphrase used to secure session cookies|n/a
|OIDC_REMOTE_USER|Which claim to use to set the REMOTE_USER variable, defaults to 'email' if not supplied|email or preferred_username
|OIDC_AUTH_COND|Any special authorisation rules to use.  Defaults to 'valid-user' if not set, see note below.|n/a
|DOMAIN|Domain where the proxy is deployed|service.domain.com
|PORT|Port on which the proxy is running and exposed|80
|SCHEME|URL scheme used to expose the proxy|https
|UPSTREAM|host and port for the upstream service being projected by the proxy. **Must end with a trailing slash.**|upstream:port/
|OIDC_SESSION_TYPE|Where the session is stored. Defaults to `server-cache`. Set to `client-cookie:persistent` for the pre-2026 behaviour.|server-cache

### OIDC_AUTH_COND

For more help filling this in, see the documentation for mod_auth_openidc here https://github.com/zmartzone/mod_auth_openidc/wiki/Authorization

## Upgrading from the ubuntu:18.04 build — read this

The base moved from Ubuntu 18.04 (Apache 2.4.29) to 24.04 (Apache 2.4.58).
Three behaviour changes come with it.

### 1. Sessions now live server-side by default

`OIDCSessionType` defaults to `server-cache` instead of
`client-cookie:persistent`. The browser carries a small session ID rather than
the whole session, taking requests from ~8 KB of headers to a few hundred bytes.
That matters because 8 KB of cookies exceeds the default header buffer of common
ingress proxies — nginx's `large_client_header_buffers` is `4 8k` — and the
failure looks like an unexplained `400` that nginx logs to its *error* log
rather than its access log, so the request appears in no access log at all.

**Two consequences:**

- **Sessions no longer survive a container restart.** shm is per-container. Fine
  for a single replica; if you run more than one you need a shared cache
  (`OIDCCacheType redis`/`memcache`) or sticky sessions, or requests landing on
  another replica will not find the session.
- **Existing users must clear cookies once.** A stale `client-cookie` session is
  2 KB+, gets used as a cache key in the new mode, exceeds shm's 512-byte key
  limit, and every request then fails. Set `OIDC_SESSION_TYPE` back to
  `client-cookie:persistent` if you would rather not deal with that.

### 2. X-Forwarded-* headers are no longer trusted implicitly

The newer `mod_auth_openidc` requires them declared, and this image now sets:

```
OIDCXForwardedHeaders X-Forwarded-Proto X-Forwarded-Host X-Forwarded-Port
```

Without it, behind a TLS-terminating proxy the module sees `http` while
`OIDCRedirectURI` says `https`, refuses to share state and session cookies, and
loops the auth flow until the state-cookie limit returns a 503. **This is the
most likely thing to break on upgrade.**

### 3. WebSockets are handled by ProxyPass, not mod_rewrite

`ProxyPass ... upgrade=websocket` (Apache ≥ 2.4.47) replaces:

```apache
RewriteRule .* ws://${UPSTREAM}%{REQUEST_URI} [P]
```

That rule was wrong, and had been since 2021. `%{REQUEST_URI}` already begins
with `/`, while `UPSTREAM` is documented as ending with one — so it produced
`ws://host:port//path`. A doubled slash makes strict routers (Go's `net/http`,
for one) answer `301`, and browsers fail a WebSocket handshake on any response
that is not `101`. **`curl` and `wget` do not reproduce it**, because both
follow the redirect and report success.

For more help filling this in, see the documentation for mod_auth_openidc here https://github.com/zmartzone/mod_auth_openidc/wiki/Authorization
