#!/bin/bash
# Runs the Apple built-in Cashu wallet tests (HavenApp/CashuWalletTests)
# against the real engine and the local test mint:
#   1. builds a host libhaven.a (c-archive, -tags cshared) into $CASHU_LIBHAVEN_DIR
#   2. serves the test mint (haven-go/wallet/swift_harness_test.go)
#   3. swift test, then stops the mint and deletes the build output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CASHU_LIBHAVEN_DIR="${CASHU_LIBHAVEN_DIR:-$(mktemp -d /private/tmp/nv-cashu-swift.XXXXXX)}"
export CASHU_SWIFT_HARNESS="$CASHU_LIBHAVEN_DIR/harness.json"
SCRATCH="$CASHU_LIBHAVEN_DIR/swift-build"
rm -f "$CASHU_SWIFT_HARNESS"

(cd "$ROOT/haven-go" && go build -mod=mod -tags cshared -buildmode=c-archive -o "$CASHU_LIBHAVEN_DIR/libhaven.a" .)

(cd "$ROOT/haven-go" && go test -count=1 -run '^TestSwiftHarnessMint$' ./wallet/) > "$CASHU_LIBHAVEN_DIR/mint.log" 2>&1 &
MINT=$!
cleanup() {
  if [ -f "$CASHU_SWIFT_HARNESS" ]; then
    curl -fsS "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["control"])' "$CASHU_SWIFT_HARNESS")/stop" >/dev/null 2>&1 || true
  fi
  wait "$MINT" 2>/dev/null || true
  [ -n "${KEEP_CASHU_BUILD:-}" ] || rm -rf "$CASHU_LIBHAVEN_DIR"
}
trap cleanup EXIT

for _ in $(seq 1 120); do [ -s "$CASHU_SWIFT_HARNESS" ] && break; sleep 0.5; done
[ -s "$CASHU_SWIFT_HARNESS" ] || { echo "test mint did not start"; cat "$CASHU_LIBHAVEN_DIR/mint.log"; exit 1; }

cd "$ROOT/HavenApp/CashuWalletTests"
swift test --scratch-path "$SCRATCH" "$@"
