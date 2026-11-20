#!/usr/bin/env bash
# build_fips_v2_android.sh
# Cross-compile the FIPS mesh library (fips-v2-android/, libnvfips.so) for the app.
#
# Companion to build_haven_android.sh, which does the same for the Go relay.
# Kotlin reaches it through com.nostrvault.fips.FipsBridge; the JNI exports are
# in the Rust crate itself, so there is no C shim and no CMake step.
#
# Prerequisites:
#   - cargo-ndk:  cargo install cargo-ndk
#   - Android NDK (set ANDROID_NDK_HOME or let this auto-detect)
#   - The targets on the toolchain fips-v2-android/rust-toolchain.toml pins:
#       rustup target add --toolchain 1.94.1 aarch64-linux-android armv7-linux-androideabi
#
# Usage:
#   ./build_fips_v2_android.sh                 # arm64-v8a + armeabi-v7a
#   ./build_fips_v2_android.sh arm64-v8a       # one ABI
#
# The default ABIs match the abi splits in app/build.gradle.kts: the release
# ships a 64-bit APK and a 32-bit one for phones (budget Samsungs) that run a
# 32-bit-only Android build.
#
# The output is gitignored, like libhaven.so, and optional: a checkout without
# it still builds and the app reports the mesh as unavailable. A release can
# therefore silently ship without the mesh — run this before cutting one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="${SCRIPT_DIR}/../fips-v2-android"
JNILIBS="${SCRIPT_DIR}/app/src/main/jniLibs"
ABIS="${*:-arm64-v8a armeabi-v7a}"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$HOME/Library/Android/sdk/ndk"/* 2>/dev/null | sort -V | tail -1 || true)"
    export ANDROID_NDK_HOME
fi
if [ -z "${ANDROID_NDK_HOME}" ] || [ ! -d "${ANDROID_NDK_HOME}" ]; then
    echo "error: Android NDK not found; set ANDROID_NDK_HOME" >&2
    exit 1
fi

rust_triple() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7-linux-androideabi" ;;
        *) echo "error: unknown ABI '$1' (arm64-v8a, armeabi-v7a)" >&2; exit 1 ;;
    esac
}

cd "${CRATE_DIR}"
TARGET_DIR="${CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
for abi in ${ABIS}; do
    triple="$(rust_triple "${abi}")"
    cargo ndk -t "${abi}" --platform 26 build --release --lib
    mkdir -p "${JNILIBS}/${abi}"
    cp "${TARGET_DIR}/${triple}/release/libnvfips.so" "${JNILIBS}/${abi}/libnvfips.so"
    echo "libnvfips.so -> ${JNILIBS}/${abi} ($(wc -c < "${JNILIBS}/${abi}/libnvfips.so") bytes)"
done
