#!/bin/bash
# Runs the Android built-in Cashu wallet tests (service/cashu) on the JVM
# against the real engine and the local test mint:
#   1. builds a host libhaven.dylib (c-shared, -tags cshared) with the app's
#      HavenBridgeJNI.c compiled in, the same way just android-build does
#      (a stub android/log.h stands in for the NDK one)
#   2. serves the test mint (haven-go/wallet/swift_harness_test.go)
#   3. runs the CashuWallet* unit tests, then stops the mint and deletes
#      the build output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
OUT="${CASHU_LIBHAVEN_DIR:-$(mktemp -d /private/tmp/nv-cashu-android.XXXXXX)}"
export CASHU_LIBHAVEN_DYLIB="$OUT/libhaven.dylib"
export CASHU_HARNESS="$OUT/harness.json"
rm -f "$CASHU_HARNESS"

mkdir -p "$OUT/stub/android"
cat > "$OUT/stub/android/log.h" <<'H'
#define ANDROID_LOG_DEBUG 3
static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) { (void)prio; (void)tag; (void)fmt; return 0; }
H
cp "$ROOT/NostrVault/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c" "$ROOT/haven-go/HavenBridgeJNI.c"
MINT=""
cleanup() {
  rm -f "$ROOT/haven-go/HavenBridgeJNI.c"
  if [ -f "$CASHU_HARNESS" ]; then
    curl -fsS "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["control"])' "$CASHU_HARNESS")/stop" >/dev/null 2>&1 || true
  fi
  [ -n "$MINT" ] && wait "$MINT" 2>/dev/null || true
  [ -n "${KEEP_CASHU_BUILD:-}" ] || rm -rf "$OUT"
}
trap cleanup EXIT

(cd "$ROOT/haven-go" && CGO_CFLAGS="-I$JAVA_HOME/include -I$JAVA_HOME/include/darwin -I$OUT/stub" \
  go build -mod=mod -tags cshared -buildmode=c-shared -o "$CASHU_LIBHAVEN_DYLIB" .)
rm -f "$ROOT/haven-go/HavenBridgeJNI.c"

(cd "$ROOT/haven-go" && CASHU_SWIFT_HARNESS="$CASHU_HARNESS" go test -count=1 -run '^TestSwiftHarnessMint$' ./wallet/) > "$OUT/mint.log" 2>&1 &
MINT=$!
for _ in $(seq 1 120); do [ -s "$CASHU_HARNESS" ] && break; sleep 0.5; done
[ -s "$CASHU_HARNESS" ] || { echo "test mint did not start"; cat "$OUT/mint.log"; exit 1; }

cd "$ROOT/NostrVault"
./gradlew --no-daemon -q :app:testDebugUnitTest --tests 'com.nostrvault.service.cashu.*' "$@"
