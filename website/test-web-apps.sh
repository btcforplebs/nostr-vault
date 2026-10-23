#!/bin/sh
# Runs the web-relay and web-vault tests against a freshly built haven.wasm, and fails if any test is skipped: the
# "real Haven" tests skip themselves when haven.wasm is missing, and a skip must not pass as green. CI runs this
# (.github/workflows/web-apps.yml); it works on a host with Go and Node too.
#   website/test-web-apps.sh             build haven.wasm, npm ci, test both apps
#   NO_WASM_BUILD=1 website/test-web-apps.sh   test with the haven.wasm already built (still fails on a skip)
set -eu
cd "$(dirname "$0")/.."

[ "${NO_WASM_BUILD:-0}" = 1 ] || web-relay/tools/build-haven-wasm.sh
for f in web-relay/public/haven.wasm web-relay/src/haven/wasm_exec.js; do
  [ -s "$f" ] || { echo "test-web-apps: missing $f, so the real Haven tests would skip" >&2; exit 1; }
done

tap=$(mktemp)
trap 'rm -f "$tap"' EXIT
failed=""
for app in web-relay web-vault; do
  echo "== $app"
  [ -d "$app/node_modules" ] && [ "${CI:-}" != true ] || (cd "$app" && npm ci --ignore-scripts --no-audit --no-fund)
  # spec to the log, tap to a file for the counts.
  (cd "$app" && node --test --test-reporter=spec --test-reporter-destination=stdout \
    --test-reporter=tap --test-reporter-destination="$tap" test/) || failed="$failed $app"
  skip=$(sed -n 's/^# skipped \([0-9]*\)$/\1/p' "$tap" | tail -n 1)
  todo=$(sed -n 's/^# todo \([0-9]*\)$/\1/p' "$tap" | tail -n 1)
  pass=$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$tap" | tail -n 1)
  echo "$app: pass ${pass:-?}, skip ${skip:-?}, todo ${todo:-?}"
  if [ "${skip:-x}" != 0 ] || [ "${todo:-x}" != 0 ]; then
    echo "test-web-apps: $app skipped tests (or no counts were read):" >&2
    grep -E '^ *(not )?ok .*# (SKIP|TODO)' "$tap" >&2 || true
    failed="$failed $app(skipped)"
  fi
done

[ -z "$failed" ] || { echo "test-web-apps: FAILED:$failed" >&2; exit 1; }
echo "test-web-apps: all passed, none skipped"
