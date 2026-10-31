#!/bin/sh
# Checks linux/: the scripts parse (and pass shellcheck when it's installed), and compose.yml is valid with an
# install's .env and refuses to start without one.
set -eu
cd "$(dirname "$0")/.."
for f in install.sh supervise.sh; do sh -n "$f"; done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh install.sh supervise.sh test/check.sh; fi
NV_OWNER=npub1xtscya34g58tk0z605fvr788k263gsu6cy9x0mhnm87echrgufzsevkk5s NV_DATA_HOST=/tmp/nv NV_PORT=8080 \
  docker compose -f compose.yml config -q
if docker compose -f compose.yml config -q >/dev/null 2>&1; then echo "compose.yml started without NV_OWNER" >&2; exit 1; fi
echo "linux/: ok"
