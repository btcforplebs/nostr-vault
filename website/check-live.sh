#!/bin/sh
# Checks a deployed nostrvault.app answers the way the site, the web apps and the thread service should. Exits 1 on
# the first run with any failure, after printing every check. deploy.sh runs it against the container it just started.
#   ./check-live.sh                          the live site (https://nostrvault.app)
#   ./check-live.sh http://localhost:4024    a container straight, as deploy.sh does
# THREAD_LINK: the /thread/ code to open (default: a public post of the vault account's, 2026-10-21). It must be a
# post that exists, so the thread service has to reach the relays and draw it.
set -u
BASE=${1:-https://nostrvault.app}
BASE=${BASE%/}
THREAD_LINK=${THREAD_LINK:-nevent1qgsxr0mepvsfftasxj2uncfk4nmpt0s0enpvh9d44na47mxwlcvtqcspz3mhxue69uhhyetvv9ujuerpd46hxtnfduqzqwrvvm9huuc60a36t2nuxrmah2p5j79yfa7vr6w675hrnz9e3prh2r0xx5}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

# get <path> [tries]: headers to $tmp/h, body to $tmp/b, status to $code. Retried, for a container still starting or
# a thread page whose relays are slow.
get() {
  tries=${2:-1}
  while :; do
    code=$(curl -s -o "$tmp/b" -D "$tmp/h" -w '%{http_code}' --max-time 30 "$BASE$1") || code=000
    [ "$code" = 200 ] || [ "$tries" -le 1 ] && return 0
    tries=$((tries - 1)); sleep 3
  done
}
header() { tr -d '\r' < "$tmp/h" | grep -i "^$1:" | tail -n 1 | cut -d: -f2- | sed 's/^ //'; }
has() { case "$1" in *"$2"*) return 0;; esac; return 1; }

# The four security headers every response carries (website/nginx.conf). $1 path, $2 "app" | "site" | "thread".
headers() {
  csp=$(header content-security-policy); xfo=$(header x-frame-options)
  case $2 in
    app) has "$csp" "'wasm-unsafe-eval'" && has "$csp" "frame-ancestors 'self'" && [ "$xfo" = SAMEORIGIN ] ;;
    site) has "$csp" "frame-ancestors 'none'" && ! has "$csp" "wasm-unsafe-eval" && [ "$xfo" = DENY ] ;;
    thread) has "$csp" "script-src https://nostrvault.app/open-post.js" && has "$csp" "default-src 'none'" && [ "$xfo" = DENY ] ;;
  esac || { bad "$1 headers: CSP \"$csp\", X-Frame-Options \"$xfo\" (want the $2 policy)"; return; }
  [ "$(header x-content-type-options)" = nosniff ] && [ "$(header referrer-policy)" = no-referrer ] \
    || { bad "$1 headers: X-Content-Type-Options / Referrer-Policy missing"; return; }
  ok "$1 headers ($2 policy)"
}

# page <path> <policy> <text the body must contain>
page() {
  get "$1" "${4:-1}"
  if [ "$code" != 200 ]; then bad "$1 is $code, want 200"; return; fi
  grep -q "$3" "$tmp/b" && ok "$1 200" || bad "$1 200 but no \"$3\" in the page"
  headers "$1" "$2"
}

echo "check-live: $BASE"
page / site '<title>Nostr Vault' 20 # the first request waits for a container that's still starting
page /docs/ site '<title>Docs'
page /relay/ app '/relay/assets/index-'
page /vault/ app '/vault/assets/index-'

# The web app's code, and the haven.wasm it runs: named inside the hashed index script.
js=$(grep -o '/vault/assets/index-[A-Za-z0-9_-]*\.js' "$tmp/b" | head -n 1)
if [ -z "$js" ]; then bad "/vault/ names no index script"; else
  get "$js"; [ "$code" = 200 ] && ok "$js 200" || bad "$js is $code"
  wasm=$(grep -o 'haven-[A-Za-z0-9_-]*\.wasm' "$tmp/b" | head -n 1)
  if [ -z "$wasm" ]; then bad "$js names no haven-*.wasm"; else
    get "/vault/assets/$wasm"
    [ "$code" = 200 ] && [ "$(header content-type)" = application/wasm ] && ok "/vault/assets/$wasm 200 application/wasm" \
      || bad "/vault/assets/$wasm is $code $(header content-type)"
  fi
fi
get /relay/haven.wasm
[ "$code" = 200 ] && [ "$(header content-type)" = application/wasm ] && ok "/relay/haven.wasm 200 application/wasm" \
  || bad "/relay/haven.wasm is $code $(header content-type)"

# A real post's public page, drawn by the thread service from the relays.
get "/thread/$THREAD_LINK" 3
if [ "$code" != 200 ]; then bad "/thread/<post> is $code, want 200 (thread service down, or the post is gone: set THREAD_LINK)"
else grep -q 'property="og:title"' "$tmp/b" && ok "/thread/<post> 200 with og:title" || bad "/thread/<post> 200 but no og:title"
  headers "/thread/<post>" thread
fi

# /v3/ was the 3.0 preview: it redirects to /vault/, keeping the path; its sw.js unregisters the old worker.
for p in /v3 /v3/ /v3/x; do
  want=/vault/${p#/v3/}; [ "$p" = /v3 ] && want=/vault/
  get "$p"; loc=$(header location)
  [ "$code" = 301 ] && [ "$loc" = "$want" ] && ok "$p 301 $loc" || bad "$p is $code \"$loc\", want 301 $want"
done
get /v3/sw.js
[ "$code" = 200 ] && grep -q unregister "$tmp/b" && ok "/v3/sw.js 200, unregisters" || bad "/v3/sw.js is $code or doesn't unregister"

if [ "$fails" -gt 0 ]; then
  echo "check-live: $fails FAILED on $BASE" >&2
  exit 1
fi
echo "check-live: all ok on $BASE"
