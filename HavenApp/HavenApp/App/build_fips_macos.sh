#!/bin/bash
# Builds libnvfips.a, the FIPS mesh engine (fips-v2-android, the same crate
# iOS and Android use), for the Mac app. Xcode runs it as a pre-build phase;
# the Swift side calls it through nvfips.h (MacFipsMeshService.swift).
#
# Skips in milliseconds when the Rust sources and the architectures are unchanged.

set -euo pipefail

if [ -z "${PROJECT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

CRATE_DIR="${PROJECT_DIR}/../fips-v2-android"
OUT_DIR="${PROJECT_DIR}/build"
LIB="${OUT_DIR}/libnvfips.a"
mkdir -p "$OUT_DIR"
cp "${CRATE_DIR}/nvfips.h" "${OUT_DIR}/nvfips.h"

# ARCHS may hold "arm64", "x86_64" or both; unset builds the native one.
TARGETS=()
for arch in ${ARCHS:-$(uname -m)}; do
    case "$arch" in
        arm64) TARGETS+=("aarch64-apple-darwin") ;;
        x86_64) TARGETS+=("x86_64-apple-darwin") ;;
    esac
done
if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "error: no macOS target for ARCHS=${ARCHS:-}" >&2
    exit 1
fi

# Xcode's PATH is minimal.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null; then
    echo "error: cargo not found; install Rust (https://rustup.rs)" >&2
    exit 1
fi

# Same inputs as build_fips_ios.sh.
CHECKSUM=$(cd "$PROJECT_DIR/.." && cat fips-v2-android/Cargo.toml fips-v2-android/Cargo.lock \
    fips-v2-android/src/*.rs fips-v2/src/stack.rs web-relay-vault/Cargo.toml web-relay-vault/src/*.rs \
    | shasum -a 256 | awk '{print $1}')
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
KEY="${CHECKSUM}-${TARGETS[*]}-${MACOSX_DEPLOYMENT_TARGET}"
STAMP="${OUT_DIR}/.libnvfips_stamp"
if [ -f "$LIB" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$KEY" ]; then
    echo "libnvfips.a unchanged for ${TARGETS[*]}, skipping."
    exit 0
fi

cd "$CRATE_DIR"
# Host and target are both macOS, so the build scripts (ring, secp256k1) get
# the macOS SDK. Xcode's own SDK and search paths are for the app.
MAC_SDK="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
SLICES=()
for target in "${TARGETS[@]}"; do
    rustup target add "$target" >/dev/null
    env -u LIBRARY_PATH -u CPATH SDKROOT="$MAC_SDK" \
        cargo rustc --release --lib --crate-type staticlib --target "$target"
    SLICES+=("${CARGO_TARGET_DIR:-target}/${target}/release/libnvfips.a")
done

if [ ${#SLICES[@]} -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$LIB"
else
    cp "${SLICES[0]}" "$LIB"
fi
echo "$KEY" > "$STAMP"
echo "libnvfips.a -> $LIB (${TARGETS[*]}, $(wc -c < "$LIB") bytes)"
