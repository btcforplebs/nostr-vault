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
#   - The target on the toolchain fips-v2-android/rust-toolchain.toml pins:
#       rustup target add --toolchain 1.94.1 aarch64-linux-android
#
# Usage:
#   ./build_fips_v2_android.sh
#
# arm64-v8a only, matching abiFilters in app/build.gradle.kts.
#
# The output is gitignored, like libhaven.so, and optional: a checkout without
# it still builds and the app reports the mesh as unavailable. A release can
# therefore silently ship without the mesh — run this before cutting one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="${SCRIPT_DIR}/../fips-v2-android"
OUTPUT_DIR="${SCRIPT_DIR}/app/src/main/jniLibs/arm64-v8a"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$HOME/Library/Android/sdk/ndk"/* 2>/dev/null | sort -V | tail -1 || true)"
    export ANDROID_NDK_HOME
fi
if [ -z "${ANDROID_NDK_HOME}" ] || [ ! -d "${ANDROID_NDK_HOME}" ]; then
    echo "error: Android NDK not found; set ANDROID_NDK_HOME" >&2
    exit 1
fi

cd "${CRATE_DIR}"
cargo ndk -t arm64-v8a --platform 26 build --release --lib

TARGET_DIR="${CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
mkdir -p "${OUTPUT_DIR}"
cp "${TARGET_DIR}/aarch64-linux-android/release/libnvfips.so" "${OUTPUT_DIR}/libnvfips.so"
echo "libnvfips.so -> ${OUTPUT_DIR} ($(wc -c < "${OUTPUT_DIR}/libnvfips.so") bytes)"
