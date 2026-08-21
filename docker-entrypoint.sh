#!/usr/bin/env sh
set -eu

# check if remoteuser value is set
OIDC_RU="${OIDC_REMOTE_USER:-email}"
export OIDC_RU=$OIDC_RU
echo "will use $OIDC_RU as source for REMOTE_USER value"

# check if specific requires condition has been given
AUTH_COND="${OIDC_AUTH_COND:-valid-user}"
export AUTH_COND="$AUTH_COND"
echo "will use the following authorisation condition Require $AUTH_COND"

# Session storage. Defaults to server-cache, which keeps the session in Apache
# shared memory and sends the browser only a session ID. client-cookie stores
# the whole session — id_token and all — in cookies, which pushes every request
# to ~8 KB of headers and runs into proxy header limits upstream.
#
# Set OIDC_SESSION_TYPE=client-cookie:persistent to restore the old behaviour,
# for example if sessions must survive a restart of this container.
OIDC_ST="${OIDC_SESSION_TYPE:-server-cache}"
export OIDC_ST="$OIDC_ST"
echo "will use $OIDC_ST for session storage"

envsubst '${SCHEME} ${PORT} ${UPSTREAM} ${OIDC_CRYPTO_PASSPRHASE} ${DOMAIN} ${OIDC_CLIENT_SECRET} ${OIDC_CLIENT_ID} ${OIDC_PROVIDER_JWKS_URI} ${OIDC_PROVIDER_METADATA_URL} ${OIDC_RU} ${AUTH_COND} ${OIDC_ST}' < /apache.conf > /etc/apache2/sites-available/000-default.conf

exec "$@"
