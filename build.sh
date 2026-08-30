#!/usr/bin/env bash
#
# Build oidc-rproxy: Apache 2.4 + mod_auth_openidc as an authenticating reverse
# proxy.
#
# WHY THIS EXISTS
#
# There was no repeatable way to produce this image. Deployments pulled it
# UNTAGGED, which meant they were running a 2021-01-30 build years after the
# source had moved on -- and a `latest` push would have moved seven gates at
# once with no way to say which build any of them was on.
#
# WHERE THE OUTPUT GOES
#
# Defaults to Docker Hub, which is what the public README documents and what
# anyone cloning this repo can push to. For the cluster copy, mirror it to the
# internal registry -- this removes a Docker Hub dependency from the
# authentication path:
#
#   ./build.sh --execute --test --push                              # public
#   ./build.sh --execute --test --push --registry int-reg.zz9pza.co # cluster
#
# The internal-CA variant (oidc-rproxy-rjk) is built separately and stacks on
# top of whatever this produces.
#
# PLATFORM
#
# Defaults to linux/amd64. Building on an aarch64 workstation and pushing the
# result silently produces an image that fails at PULL time on an amd64 node,
# which does not look like an architecture mistake when it happens.
#
# WHAT --test PROVES
#
# It runs the built image with a real IdP metadata URL and dummy credentials,
# then asserts on the response to an unauthenticated request:
#
#   - a 302 to the IdP        -- Apache started, the config templated, and the
#                                module fetched and parsed the discovery doc
#   - a state cookie is set   -- the flow actually began
#   - SameSite=None on it     -- THE REGRESSION GUARD. mod_auth_openidc 2.4.15
#                                sets SameSite=Lax by default, which silently
#                                breaks every IdP on a different registrable
#                                domain: the redirect out succeeds and the
#                                CALLBACK fails with 400. Nothing before the
#                                callback shows a fault, so this is the only
#                                cheap place to catch it. See the long comment
#                                on OIDCCookieSameSite in config/oidc_auth.conf.
#
# Dummy client credentials are fine: none of the above reaches token exchange.
#
# USAGE
#
#   ./build.sh                              # plan, change nothing
#   ./build.sh --execute                    # build
#   ./build.sh --execute --test             # build and test
#   ./build.sh --execute --test --push      # build, test, publish
#   ./build.sh --tag 2026-08-30b ...        # same-day rebuild
#
# MOVING `latest` -- read before using --also-latest
#
# --also-latest additionally pushes the same build as :latest. This is normally
# the exact fault dated tags exist to prevent: anything pulling :latest moves
# underneath itself with no rollout and no record of which build it got.
#
# It is defensible only when NOTHING is pinned to :latest. That was true on
# 2026-08-30 and is why it was used then: every pc2 gate had just been repinned
# to dated int-reg tags, so :latest on Docker Hub had no consumers, while still
# serving a 2021-01-30 build on EOL Ubuntu 18.04 that this repo's README
# described as if it were the current one.
#
# Check before reaching for it. If anything is pinned to :latest, push the dated
# tag alone and let consumers move deliberately.
#
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="docker.io/richardjkendall"
NAME="oidc-rproxy"
TAG="$(date +%Y-%m-%d)"
PLATFORM="linux/amd64"
TEST_PORT="18120"

# A real, public, stable discovery document. Google's is used because the bug
# --test guards against is specifically the cross-site-IdP one.
TEST_METADATA="https://accounts.google.com/.well-known/openid-configuration"
TEST_JWKS="https://www.googleapis.com/oauth2/v3/certs"
TEST_DOMAIN="gate.example.com"

EXECUTE=0; PUSH=0; TEST=0; ALSO_LATEST=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --execute)  EXECUTE=1 ;;
    --test)     TEST=1 ;;
    --push)     PUSH=1 ;;
    --also-latest) ALSO_LATEST=1 ;;
    --tag)      shift; [ $# -gt 0 ] || die "--tag needs a value"; TAG="$1" ;;
    --registry) shift; [ $# -gt 0 ] || die "--registry needs a value"; REGISTRY="$1" ;;
    --platform) shift; [ $# -gt 0 ] || die "--platform needs a value"; PLATFORM="$1" ;;
    -h|--help)  sed -n '2,62p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
  shift
done

IMG="$REGISTRY/$NAME:$TAG"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

say "oidc-rproxy build"
say "================="
say "  target    $IMG"
say "  platform  $PLATFORM"
say "  test      $([ "$TEST" = 1 ] && echo yes || echo no)"
say "  push      $([ "$PUSH" = 1 ] && echo yes || echo no)"
say ""

if [ "$EXECUTE" = 0 ]; then
  say "PLAN ONLY -- nothing was built."
  say "Re-run with --execute."
  exit 0
fi

say "building..."
docker buildx build --platform "$PLATFORM" -t "$IMG" --load .
say ""

# --- test ------------------------------------------------------------------

run_tests() {
  local cid="" rc=0

  if lsof -iTCP:"$TEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "something is already listening on $TEST_PORT -- a stale container would
       make these tests report another build's behaviour"
  fi

  cid="$(docker run -d --rm -p "$TEST_PORT:80" \
    -e "OIDC_PROVIDER_METADATA_URL=$TEST_METADATA" \
    -e "OIDC_PROVIDER_JWKS_URI=$TEST_JWKS" \
    -e "OIDC_CLIENT_ID=test-client" \
    -e "OIDC_CLIENT_SECRET=test-secret" \
    -e "OIDC_CRYPTO_PASSPRHASE=test-passphrase-not-a-real-one" \
    -e "DOMAIN=$TEST_DOMAIN" \
    -e "UPSTREAM=127.0.0.1:9/" \
    -e "PORT=443" -e "SCHEME=https" \
    "$IMG")" || die "container failed to start"
  trap 'docker kill '"$cid"' >/dev/null 2>&1 || true' EXIT

  local i hdrs=""
  for i in $(seq 1 20); do
    sleep 1
    hdrs="$(curl -s -D - -o /dev/null \
              -H "Host: $TEST_DOMAIN" -H 'X-Forwarded-Proto: https' \
              "http://127.0.0.1:$TEST_PORT/" 2>/dev/null)" || true
    [ -n "$hdrs" ] && break
  done
  [ -n "$hdrs" ] || { docker logs "$cid" 2>&1 | tail -20; die "no response from the container"; }

  local status cookie
  status="$(printf '%s' "$hdrs" | awk 'NR==1{print $2}')"
  cookie="$(printf '%s' "$hdrs" | grep -i '^set-cookie:.*mod_auth_openidc_state' || true)"

  say "  test 1: redirects to the IdP"
  if [ "$status" = "302" ]; then
    say "          ok: 302"
  else
    say "          FAIL: got $status, expected 302"
    docker logs "$cid" 2>&1 | grep -v AH00558 | tail -10 | sed 's/^/            /'
    rc=1
  fi

  say "  test 2: sets a state cookie"
  if [ -n "$cookie" ]; then
    say "          ok"
  else
    say "          FAIL: no mod_auth_openidc_state cookie in the response"; rc=1
  fi

  # THE REGRESSION GUARD. See the header.
  say "  test 3: state cookie is SameSite=None"
  case "$cookie" in
    *SameSite=None*) say "          ok" ;;
    *SameSite=Lax*)  say "          FAIL: SameSite=Lax -- cross-site IdP callbacks WILL 400."
                     say "                OIDCCookieSameSite None is missing or was overridden."; rc=1 ;;
    *)               say "          FAIL: no SameSite attribute on the state cookie."
                     say "                That only works via Chrome's Lax+POST grace, which is"
                     say "                being removed. Set OIDCCookieSameSite None."; rc=1 ;;
  esac

  say "  test 4: cookie is Secure"
  case "$cookie" in
    *Secure*) say "          ok" ;;
    *)        say "          FAIL: SameSite=None is ignored without Secure"; rc=1 ;;
  esac

  docker kill "$cid" >/dev/null 2>&1 || true
  trap - EXIT
  return $rc
}

if [ "$TEST" = 1 ]; then
  say "testing $IMG..."
  run_tests || die "tests FAILED -- not pushing"
  say ""
  say "  all tests passed"
  say ""
fi

if [ "$PUSH" = 0 ]; then
  say "Built$([ "$TEST" = 1 ] && echo " and tested"). NOT pushed -- re-run with --push."
  exit 0
fi

say "checking $IMG is not already published..."
if docker buildx imagetools inspect "$IMG" >/dev/null 2>&1; then
  die "$IMG ALREADY EXISTS.
       Republishing a tag something is pinned to is never safe. Use --tag ${TAG}b"
fi
say "  ok: tag is free"
say ""

say "pushing $IMG..."
docker buildx build --platform "$PLATFORM" -t "$IMG" --push .
say ""
if [[ "$ALSO_LATEST" == 1 ]]; then
  say ""
  say "also pushing $REGISTRY/$NAME:latest (see the header on when this is defensible)..."
  docker buildx build --platform "$PLATFORM" -t "$REGISTRY/$NAME:latest" --push .
  say "  moved :latest to this build"
fi

say "Done. $IMG is published."
