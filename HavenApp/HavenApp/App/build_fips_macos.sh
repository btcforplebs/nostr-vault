#!/bin/bash
#
# Builds libfips_bridge_ffi.a (the Rust FIPS mesh bridge) for the macOS app and
# copies the C header next to it, so the bridging header can include it.
#
# Mirrors build_haven.sh: same output directory, same ARCHS handling, same
# "hash the sources and exit early" trick — Xcode skips a phase that declares an
# output and no inputs once the file exists, which silently strands every later
# source change.

set -e

if [ -z "$PROJECT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# The Rust workspace is a sibling of the Xcode project directory.
FIPS_SRC_ROOT="${PROJECT_DIR}/../fips-bridge"
OUT_DIR="${PROJECT_DIR}/build"
FIPS_LIB_PATH="${OUT_DIR}/libfips_bridge_ffi.a"
# One header, shared with the iOS probe. Copied rather than included in place so
# HEADER_SEARCH_PATHS stays the single "$(PROJECT_DIR)/build" it already is.
FIPS_HEADER_SRC="${FIPS_SRC_ROOT}/ios-probe/Sources/fips_bridge.h"
CHECKSUM_FILE="${OUT_DIR}/.libfips_bridge_checksum"

# Xcode uses a minimal PATH — cargo lives in the user's home.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# ring compiles C through the `cc` crate, which otherwise targets the host OS
# version. Without this the link emits one "built for newer macOS version"
# warning per object file, ~40 of them, and the archive is not actually built
# for the version the app deploys to.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

CARGO_BIN=$(which cargo 2>/dev/null || true)
if [ -z "$CARGO_BIN" ]; then
    echo "❌ Error: 'cargo' not found. Install Rust (https://rustup.rs)."
    exit 1
fi

mkdir -p "$OUT_DIR"

cd "$FIPS_SRC_ROOT"

# ── Source-change detection ──────────────────────────────────────────
CURRENT_CHECKSUM=$( (find crates -name '*.rs' | sort | xargs cat; cat Cargo.toml rust-toolchain.toml "$FIPS_HEADER_SRC") | shasum -a 256 | awk '{print $1}')

if [ -f "$FIPS_LIB_PATH" ] && [ -f "${OUT_DIR}/fips_bridge.h" ] && [ -f "$CHECKSUM_FILE" ]; then
    if [ "$CURRENT_CHECKSUM" = "$(cat "$CHECKSUM_FILE")" ]; then
        echo "✅ FIPS bridge source unchanged — skipping rebuild."
        exit 0
    fi
fi

# Determine which architectures to build. ARCHS may hold either or both.
NEED_ARM64=false
NEED_X86_64=false
for arch in $ARCHS; do
    case "$arch" in
        arm64)  NEED_ARM64=true ;;
        x86_64) NEED_X86_64=true ;;
    esac
done
if ! $NEED_ARM64 && ! $NEED_X86_64; then
    if [ "$(uname -m)" = "arm64" ]; then NEED_ARM64=true; else NEED_X86_64=true; fi
fi

# rust-toolchain.toml pins `stable` for this workspace, so the target has to be
# installed on `stable` specifically — `rustup target add` without --toolchain
# lands on the default toolchain and the build then fails with
# "can't find crate for `core`" while `rustup target list --installed` looks fine.
build_for_target() {
    local target=$1
    local output=$2
    echo "🛠️ Building fips-bridge-ffi for $target..."
    rustup target add --toolchain stable "$target" >/dev/null 2>&1 || true
    cargo build --release --target "$target" -p fips-bridge-ffi
    cp "${FIPS_SRC_ROOT}/target/${target}/release/libfips_bridge_ffi.a" "$output"
}

if $NEED_ARM64 && $NEED_X86_64; then
    ARM64_LIB="${OUT_DIR}/libfips_bridge_ffi-arm64.a"
    X86_64_LIB="${OUT_DIR}/libfips_bridge_ffi-x86_64.a"
    build_for_target aarch64-apple-darwin "$ARM64_LIB"
    build_for_target x86_64-apple-darwin "$X86_64_LIB"
    echo "🔗 Creating universal archive with lipo..."
    lipo -create "$ARM64_LIB" "$X86_64_LIB" -output "$FIPS_LIB_PATH"
    rm -f "$ARM64_LIB" "$X86_64_LIB"
elif $NEED_ARM64; then
    build_for_target aarch64-apple-darwin "$FIPS_LIB_PATH"
else
    build_for_target x86_64-apple-darwin "$FIPS_LIB_PATH"
fi

cp "$FIPS_HEADER_SRC" "${OUT_DIR}/fips_bridge.h"

# ── Export gate ──────────────────────────────────────────────────────
# A static archive that links but exports nothing is the failure this catches:
# the Swift side would then fail at link with an undefined symbol per call, one
# error at a time, in a build log nobody reads to the bottom.
MISSING=0
for sym in FipsBridgeStartWithIdentity FipsBridgeGenerateNsec FipsBridgeExport \
           FipsBridgeIngress FipsBridgeStatusJSON FipsBridgeStop FipsBridgeFreeString; do
    if ! nm "$FIPS_LIB_PATH" 2>/dev/null | grep -q "T _${sym}$"; then
        echo "❌ missing export: $sym"
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    rm -f "$CHECKSUM_FILE"
    exit 1
fi

echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "✅ $FIPS_LIB_PATH"
