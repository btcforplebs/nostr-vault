#!/bin/bash
# Builds libnvfips.a, the FIPS mesh engine (fips-v2-android, the same crate
# Android uses), for the iOS app. Xcode runs it as a pre-build phase; the
# Swift side calls it through nvfips.h (FipsMeshService.swift).
#
# Skips in milliseconds when the Rust sources and the platform are unchanged.

set -euo pipefail

if [ -z "${PROJECT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

CRATE_DIR="${PROJECT_DIR}/../fips-v2-android"
OUT_DIR="${PROJECT_DIR}/build/ios"
LIB="${OUT_DIR}/libnvfips.a"
mkdir -p "$OUT_DIR"
cp "${CRATE_DIR}/nvfips.h" "${OUT_DIR}/nvfips.h"

if [[ "${PLATFORM_NAME:-iphoneos}" == "iphonesimulator" ]]; then
    TARGET="aarch64-apple-ios-sim"
else
    TARGET="aarch64-apple-ios"
fi

# Xcode's PATH is minimal.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null; then
    echo "error: cargo not found; install Rust (https://rustup.rs)" >&2
    exit 1
fi

# The fork pin lives in Cargo.toml/Cargo.lock; stack.rs is shared with fips-v2.
CHECKSUM=$(cd "$PROJECT_DIR/.." && cat fips-v2-android/Cargo.toml fips-v2-android/Cargo.lock \
    fips-v2-android/src/*.rs fips-v2/src/stack.rs | shasum -a 256 | awk '{print $1}')
STAMP="${OUT_DIR}/.libnvfips_stamp"
if [ -f "$LIB" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "${CHECKSUM}-${TARGET}-${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" ]; then
    echo "libnvfips.a unchanged for ${TARGET}, skipping."
    exit 0
fi

cd "$CRATE_DIR"
rustup target add "$TARGET" >/dev/null
# Xcode's SDK settings point at iOS; host build scripts (ring, secp256k1)
# must not see them, or they link against the wrong SDK. The deployment
# target is kept: without it the C objects are built for the SDK's iOS.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
env -u SDKROOT -u LIBRARY_PATH -u CPATH \
    cargo rustc --release --lib --crate-type staticlib --target "$TARGET"

cp "target/${TARGET}/release/libnvfips.a" "$LIB"
echo "${CHECKSUM}-${TARGET}-${IPHONEOS_DEPLOYMENT_TARGET}" > "$STAMP"
echo "libnvfips.a -> $LIB ($TARGET, $(wc -c < "$LIB") bytes)"
