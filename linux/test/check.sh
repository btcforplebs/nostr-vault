#!/bin/sh
# Checks linux/: the scripts parse (and pass shellcheck when it's installed), and compose.yml is valid with a
# .env and refuses to start without one.
set -eu
cd "$(dirname "$0")/.."
native="native/build.sh native/package.sh native/bin/nostr-vault-setup native/lib/prepare native/debian/postinst native/debian/prerm native/debian/postrm"
for f in supervise.sh $native; do sh -n "$f"; done
# shellcheck disable=SC2086
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh supervise.sh test/check.sh $native; fi
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' native/desktop/nostr-vault-desktop
if command -v systemd-analyze >/dev/null 2>&1; then
  # A unit that systemd finds fault with fails the check (missing binaries and users are expected off-box).
  bad=$(for u in native/systemd/*.service; do systemd-analyze verify --man=no "$u" 2>&1; done \
    | grep -v -e 'not found' -e 'is not executable' -e 'Unit .* is not loaded' -e 'Failed to prepare' -e 'Failed to resolve user' -e 'Failed to resolve group' -e 'Command .* is not' || true)
  [ -z "$bad" ] || { printf '%s\n' "$bad" >&2; exit 1; }
fi
if command -v desktop-file-validate >/dev/null 2>&1; then desktop-file-validate native/desktop/*.desktop; fi
command -v docker >/dev/null 2>&1 || { echo "linux/: ok (no docker here: compose.yml not checked)"; exit 0; }
NV_OWNER=npub1xtscya34g58tk0z605fvr788k263gsu6cy9x0mhnm87echrgufzsevkk5s NV_DATA_HOST=/tmp/nv NV_PORT=8080 \
  docker compose -f compose.yml config -q
if docker compose -f compose.yml config -q >/dev/null 2>&1; then echo "compose.yml started without NV_OWNER" >&2; exit 1; fi
echo "linux/: ok"
