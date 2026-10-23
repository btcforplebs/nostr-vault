#!/bin/sh
# Publishes the site as an nsite (NIP-5A), the same files nostrvault.app serves: uploads them to Blossom and signs the
# manifest with the site key (nsite/publish.mjs). deploy.sh runs it after each deploy and rollback; the address is
# printed at the end (https://<site npub>.nsite.lol/).
#   ./publish-nsite.sh          the site in the running website container (what deploy.sh just started)
#   ./publish-nsite.sh <dir>    a built site dir, e.g. website/ after build-web-apps.sh on a host without Docker
# NSITE_KEY: the site's nsec file, default the one *.nsec in ~/.nostrvault-site/ (chmod 600). Never commit it.
set -eu
dir=${1:+$(cd "$1" && pwd)}
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -z "$dir" ]; then
  running=$(docker compose ps -q website 2>/dev/null | head -n 1)
  [ -n "$running" ] || { echo "publish-nsite: no running website container; pass a built site dir" >&2; exit 1; }
  docker cp "$running:/usr/share/nginx/html" "$tmp/site"
  dir=$tmp/site
fi

[ -d nsite/node_modules ] || npm ci --prefix nsite --ignore-scripts --no-audit --no-fund
node nsite/publish.mjs "$dir"
