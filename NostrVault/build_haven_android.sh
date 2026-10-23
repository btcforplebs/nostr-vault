#!/usr/bin/env bash
# build_haven_android.sh
# Cross-compile the Haven Go relay into Android .so libraries via CGO.
#
# Prerequisites:
#   - Go 1.22+ installed
#   - Android NDK r26+ installed (set ANDROID_NDK_HOME or auto-detect)
#   - gomobile: go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
#
# Usage:
#   ./build_haven_android.sh              # Build all ABIs
#   ./build_haven_android.sh arm64        # Build only arm64-v8a
#   ./build_haven_android.sh clean        # Remove built .so files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_SRC_DIR="${SCRIPT_DIR}/../haven-go"
OUTPUT_BASE="${SCRIPT_DIR}/app/src/main/jniLibs"
JNI_BRIDGE_SRC="${SCRIPT_DIR}/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c"

# Android NDK auto-detection
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    # Common locations
    for candidate in \
        "$HOME/Library/Android/sdk/ndk"/* \
        "$HOME/Android/Sdk/ndk"/* \
        "/usr/local/lib/android/sdk/ndk"/*; do
        if [ -d "$candidate" ]; then
            ANDROID_NDK_HOME="$candidate"
            break
        fi
    done
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: ANDROID_NDK_HOME not set and NDK not found in common locations."
    echo "Install via: sdkmanager --install 'ndk;26.1.10909125'"
    exit 1
fi

echo "Using NDK: ${ANDROID_NDK_HOME}"

# NDK toolchain bin directory
NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
if [ "$(uname)" = "Darwin" ]; then
    NDK_HOST="darwin-x86_64"
elif [ "$(uname)" = "Linux" ]; then
    NDK_HOST="linux-x86_64"
else
    echo "ERROR: Unsupported host OS: $(uname)"
    exit 1
fi
NDK_BIN="${NDK_TOOLCHAIN}/${NDK_HOST}/bin"

# API level (minSdk 26 = Android 8.0)
API_LEVEL=26

# ABI -> (GOARCH, CC triple) mapping.
#
# Deliberately NOT an associative array: macOS ships bash 3.2, which has no
# `declare -A`, so this script aborted at parse time with
# "declare: -A: invalid option" whenever it was invoked directly — including
# from release_all.sh, which meant the Android stage of a release never ran.
# It only appeared to work because `just android-build` cross-compiles inline
# and never calls this file.
ALL_ABIS="arm64-v8a armeabi-v7a x86_64"

# Accepts the jniLibs ABI names and the GOARCH-style shorthands the usage text
# above advertises. release_all.sh passes "arm64", which the old lookup rejected
# outright — so even once the parse error was fixed the Android stage still
# failed on its own documented invocation.
normalize_abi() {
    case "$1" in
        arm64|arm64-v8a)      echo "arm64-v8a" ;;
        arm|armeabi-v7a)      echo "armeabi-v7a" ;;
        amd64|x86_64)         echo "x86_64" ;;
        *)                    echo "" ;;
    esac
}

abi_map() { # abi_map <abi> -> "goarch:cc-triple", empty if unknown
    case "$(normalize_abi "$1")" in
        arm64-v8a)   echo "arm64:aarch64-linux-android${API_LEVEL}-clang" ;;
        armeabi-v7a) echo "arm:armv7a-linux-androideabi${API_LEVEL}-clang" ;;
        x86_64)      echo "amd64:x86_64-linux-android${API_LEVEL}-clang" ;;
        *)           echo "" ;;
    esac
}

build_abi() {
    local abi; abi="$(normalize_abi "$1")"
    local spec; spec="$(abi_map "$abi")"
    local goarch="${spec%%:*}"
    local cc="${spec##*:}"
    local output_dir="${OUTPUT_BASE}/${abi}"
    local output_file="${output_dir}/libhaven.so"

    echo "Building ${abi} (GOARCH=${goarch})..."

    mkdir -p "${output_dir}"

    # Use Go 1.24.x for c-shared builds — Go 1.26+ has GC regressions
    # in c-shared mode on Android ARM64 (span corruption / bad heap pointers).
    local GO_CMD="${GO_CMD:-go}"
    if command -v go1.24.4 &>/dev/null; then
        GO_CMD="go1.24.4"
    fi

    # CGO has to compile the JNI bridge into the .so, so it must sit inside the
    # Go module for the duration of the build. The justfile did this; this
    # script did not, so anything it produced would have lacked every JNI entry
    # point the app calls. Removed again afterwards, including on failure.
    cp "${JNI_BRIDGE_SRC}" "${GO_SRC_DIR}/HavenBridgeJNI.c"
    trap 'rm -f "${GO_SRC_DIR}/HavenBridgeJNI.c"' RETURN

    # Build from inside the module. Passing the source dir as a package path
    # while cwd is NostrVault/ makes Go look for a main module here and fail
    # with "cannot find main module" — the justfile's inline build always cd'd
    # in first, which is why that path worked and this script never did.
    ( cd "${GO_SRC_DIR}" && \
      CGO_ENABLED=1 \
      GOOS=android \
      GOARCH="${goarch}" \
      CC="${NDK_BIN}/${cc}" \
      CGO_CFLAGS="-DMDB_USE_ROBUST=0" \
      ${GO_CMD} build \
          -mod=mod -buildmode=c-shared \
          -tags "cshared libsecp256k1" \
          -trimpath \
          -ldflags="-s -w" \
          -o "${output_file}" \
          . )

    # Remove the generated .h file (we define our own JNI bridge)
    rm -f "${output_dir}/libhaven.h"

    local size
    size=$(du -h "${output_file}" | cut -f1)
    echo "  -> ${output_file} (${size})"
}

clean() {
    echo "Cleaning built .so files..."
    for abi in $ALL_ABIS; do
        rm -f "${OUTPUT_BASE}/${abi}/libhaven.so"
        rm -f "${OUTPUT_BASE}/${abi}/libhaven.h"
    done
    echo "Clean complete."
}

# Parse arguments
if [ "${1:-}" = "clean" ]; then
    clean
    exit 0
fi

if [ -n "${1:-}" ]; then
    # Build specific ABI
    if [ -z "$(abi_map "${1}")" ]; then
        echo "ERROR: Unknown ABI '${1}'. Valid: ${ALL_ABIS}"
        exit 1
    fi
    build_abi "$1"
else
    # Build all ABIs
    for abi in arm64-v8a armeabi-v7a x86_64; do
        build_abi "$abi"
    done
fi

echo ""
echo "Build complete. .so files are in ${OUTPUT_BASE}/"
ls -la "${OUTPUT_BASE}"/*/libhaven.so 2>/dev/null || true
