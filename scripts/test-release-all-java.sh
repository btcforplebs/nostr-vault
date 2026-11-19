#!/usr/bin/env bash
# Checks that release_all.sh refuses to start the Android stage without a JDK,
# before any native build, and accepts a working one. Nothing is built: the
# good-JDK cases use --check, and the bad ones stop at the preflight.
#
#   scripts/test-release-all-java.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/release_all.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A `java` that fails, like macOS's /usr/bin/java stub with no JDK installed,
# ahead of everything else on PATH.
mkdir -p "$TMP/nojava" "$TMP/goodjbr/bin"
printf '#!/bin/sh\necho "Unable to locate a Java Runtime." >&2\nexit 1\n' > "$TMP/nojava/java"
printf '#!/bin/sh\nexit 0\n' > "$TMP/goodjbr/bin/java"
chmod +x "$TMP/nojava/java" "$TMP/goodjbr/bin/java"

fails=0
check() { # check <name> <expected exit: 0|nonzero> <must-contain> <must-not-contain> -- env...
    local name="$1" want="$2" has="$3" hasnt="$4"; shift 5
    local out code
    out="$(env -u JAVA_HOME "$@" PATH="$TMP/nojava:$PATH" "$SCRIPT" --skip-ios --skip-macos --skip-publish --yes ${CHECK:+--check} 2>&1)"
    code=$?
    local ok=1
    if [ "$want" = 0 ]; then [ "$code" = 0 ] || ok=0; else [ "$code" != 0 ] || ok=0; fi
    grep -qF -- "$has" <<< "$out" || ok=0
    if [ -n "$hasnt" ] && grep -qF -- "$hasnt" <<< "$out"; then ok=0; fi
    if [ "$ok" = 1 ]; then echo "PASS $name (exit $code)"; else
        echo "FAIL $name (exit $code)"; tail -5 <<< "$out" | sed 's/^/    /'; fails=$((fails + 1)); fi
}

# No JDK anywhere: fails at once, never reaches the Go/Rust/C++ builds.
check "no JDK -> exit non-zero before the native builds" nonzero "No JDK" "Android: rebuilding" -- \
    ANDROID_STUDIO_JBR="$TMP/missing"
# A JAVA_HOME that points nowhere is not silently replaced.
check "broken JAVA_HOME -> exit non-zero" nonzero "No JDK" "Android: rebuilding" -- \
    JAVA_HOME="$TMP/missing" ANDROID_STUDIO_JBR="$TMP/goodjbr"
# --check reports the missing JDK, and finds Android Studio's when present.
CHECK=1 check "--check reports no JDK" 0 "no JDK (set JAVA_HOME)" "" -- ANDROID_STUDIO_JBR="$TMP/missing"
CHECK=1 check "--check finds the Android Studio JBR" 0 "JDK: Android Studio JBR" "" -- ANDROID_STUDIO_JBR="$TMP/goodjbr"

[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
