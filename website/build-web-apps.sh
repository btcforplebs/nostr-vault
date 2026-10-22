#!/bin/sh
# Builds the browser apps into the site, so nostrvault.app serves them:
#   web-relay/ -> website/relay/   (vite writes there itself)
#   web-vault/ -> website/vault/   (vite writes web-vault/dist/, copied here)
# Runs inside website/Dockerfile at deploy time; also works on a host with Go and Node.
# Both apps are required: a site without them ships /relay/ and /vault/ as 404.
# ALLOW_MISSING_WEB_APPS=1 builds the pages alone, for a checkout that predates the apps.
set -eu
cd "$(dirname "$0")/.."

missing=""
[ -d web-relay ] || missing="$missing web-relay/"
[ -d web-vault ] || missing="$missing web-vault/"
if [ -n "$missing" ]; then
  if [ "${ALLOW_MISSING_WEB_APPS:-0}" = 1 ]; then
    echo "build-web-apps: ALLOW_MISSING_WEB_APPS=1, building the pages only (missing:$missing)"
    exit 0
  fi
  echo "build-web-apps: missing$missing, so /relay/ and /vault/ would be 404. Set ALLOW_MISSING_WEB_APPS=1 to deploy the pages anyway." >&2
  exit 1
fi

# Asserts a build wrote what the site serves, not just an index.html.
need() { for f in "$@"; do [ -s "$f" ] || { echo "build-web-apps: missing or empty $f" >&2; exit 1; }; done; }

web-relay/tools/build-haven-wasm.sh
(cd web-relay && npm ci --ignore-scripts --no-audit --no-fund && npm run build)
need website/relay/index.html website/relay/haven.wasm website/relay/haven.wasm.gz website/relay/sw.js website/relay/share-photos.js
ls website/relay/assets/index-*.js >/dev/null

# web-vault imports web-relay's code and haven.wasm, so it builds second.
(cd web-vault && npm ci --ignore-scripts --no-audit --no-fund && npm run build)
rm -rf website/vault
cp -R web-vault/dist website/vault
need website/vault/index.html website/vault/sw.js
ls website/vault/assets/haven-*.wasm.gz website/vault/assets/index-*.js >/dev/null
