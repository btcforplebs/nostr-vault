#!/usr/bin/env bash
# build_fips_android.sh
# Cross-compile the Rust FIPS mesh bridge into Android .so libraries.
#
# Companion to build_haven_android.sh, which does the same for the Go relay.
# The C ABI it produces is the one HavenApp links on macOS/iOS — Android gets
# the same surface through FipsBridgeJNI.c, so there is one implementation.
#
# Prerequisites:
#   - rustup, and cargo-ndk:  cargo install cargo-ndk
#   - Android NDK (set ANDROID_NDK_HOME or let this auto-detect)
#   - The Rust targets, on the toolchain fips-bridge/rust-toolchain.toml pins
#     (stable — NOT your default toolchain, which is where `rustup target add`
#     puts them unless you say otherwise):
#       rustup target add --toolchain stable aarch64-linux-android x86_64-linux-android
#
# Usage:
#   ./build_fips_android.sh              # arm64-v8a (what the app ships)
#   ./build_fips_android.sh x86_64       # emulator
#
# armeabi-v7a is NOT buildable: nvpn-fips-core 0.4.72 does not compile for
# 32-bit ARM (upper/dns.rs:277 assigns a u32 to msg_namelen, which is i32 on
# that target). It is also not shipped — app/build.gradle.kts filters ABIs down
# to arm64-v8a — so this costs nothing today. Do not add armeabi-v7a to
# abiFilters without fixing that upstream first.
#
# The output is gitignored, exactly like libhaven.so, and CMakeLists.txt treats
# it as optional: a checkout without it still builds and the app reports the
# mesh as unavailable. That means a release can silently ship without the mesh
# — run this before cutting one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_WORKSPACE="${SCRIPT_DIR}/../fips-bridge"
OUTPUT_BASE="${SCRIPT_DIR}/app/src/main/jniLibs"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for candidate in \
        "$HOME/Library/Android/sdk/ndk"/* \
        "$HOME/Android/Sdk/ndk"/* \
        "/usr/local/lib/android/sdk/ndk"/*; do
        if [ -d "$candidate" ]; then
            ANDROID_NDK_HOME="$candidate"
        fi
    done
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: ANDROID_NDK_HOME not set and no NDK found in the usual places." >&2
    exit 1
fi
export ANDROID_NDK_HOME

if ! command -v cargo-ndk &>/dev/null; then
    echo "ERROR: cargo-ndk not installed. Run: cargo install cargo-ndk" >&2
    exit 1
fi

ABI="${1:-arm64-v8a}"

echo "Building fips-bridge-ffi for ${ABI}"
echo "  NDK:       ${ANDROID_NDK_HOME}"
echo "  workspace: ${RUST_WORKSPACE}"

# --locked on purpose: the pinned nvpn-fips-endpoint publishes several times a
# day. See fips-bridge/README.md.
( cd "${RUST_WORKSPACE}" && \
  cargo ndk -t "${ABI}" -o "${OUTPUT_BASE}" build --release -p fips-bridge-ffi --locked )

SO="${OUTPUT_BASE}/${ABI}/libfips_bridge_ffi.so"
if [ ! -f "${SO}" ]; then
    echo "ERROR: expected ${SO} and it is not there." >&2
    exit 1
fi

# The build can succeed and still produce a library the JNI shim cannot link
# against, so check for the symbols rather than for the file.
NM="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm"
if [ -x "${NM}" ]; then
    missing=0
    for sym in FipsBridgeStartWithIdentity FipsBridgeGenerateNsec FipsBridgeStatusJSON \
               FipsBridgeExport FipsBridgeIngress FipsBridgeStop FipsBridgeFreeString; do
        if ! "${NM}" -D --defined-only "${SO}" | grep -q " T ${sym}\$"; then
            echo "  MISSING EXPORT: ${sym}" >&2
            missing=1
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        echo "ERROR: ${SO} is missing exports the JNI shim declares." >&2
        exit 1
    fi
    echo "  exports: all present"
fi

echo "  -> ${SO} ($(du -h "${SO}" | cut -f1))"
