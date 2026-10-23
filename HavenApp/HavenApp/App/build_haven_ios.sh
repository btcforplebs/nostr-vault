#!/bin/bash

# This script builds the Go 'haven' binary for iOS from the root of the project.
# It is intended to be run as an Xcode Run Script phase for iOS builds.
#
# iOS-specific considerations:
# - Uses GOOS=ios with GOARCH=arm64
# - Requires iOS SDK toolchain (clang from xcrun)
# - Static library linking into the main app bundle

set -e

# The Go source is at the root of the workspace (one level up from HavenApp project dir)
# If PROJECT_DIR is not set, determine it relative to this script
if [ -z "$PROJECT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

GO_SRC_ROOT="${PROJECT_DIR}/../haven-go"

if [ -z "$BUILT_PRODUCTS_DIR" ]; then
    echo "⚠️ BUILT_PRODUCTS_DIR not set. Using local build directory."
    BUILT_PRODUCTS_DIR="${PROJECT_DIR}/build"
    CONTENTS_FOLDER_PATH="Haven.app/Contents"
fi

# Build into the Xcode project build directory so it can be linked.
HAVEN_LIB_PATH="${PROJECT_DIR}/build/ios/libhaven_ios.a"

echo "🚀 Building Go libhaven_ios.a for iOS from source..."
echo "📍 Source root: $GO_SRC_ROOT"
echo "📍 Output path: $HAVEN_LIB_PATH"

export GOOS="ios"
export CGO_ENABLED=1

# iOS deployment target - use 15.0 as minimum for modern iOS features
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

# Xcode uses a minimal PATH — add common Go install locations
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"

GO_BIN=$(which go 2>/dev/null || true)

if [ -z "$GO_BIN" ]; then
    echo "❌ Error: 'go' command not found. Please install Go (https://go.dev/doc/install)."
    exit 1
fi

cd "$GO_SRC_ROOT"

# ── Source-change detection ──────────────────────────────────────────
# Hash all Go source files + go.mod/go.sum to detect changes.
# If nothing changed since the last successful build, skip recompilation.
# Include PLATFORM_NAME in the checksum file so simulator vs device rebuilds correctly.
CHECKSUM_FILE="${PROJECT_DIR}/build/ios/.libhaven_ios_checksum_${PLATFORM_NAME:-ios}"
CURRENT_CHECKSUM=$(find . -name '*.go' -o -name 'go.mod' -o -name 'go.sum' | sort | xargs cat | shasum -a 256 | awk '{print $1}')

# Track which platform the current .a was built for. The checksum files are
# platform-specific but the .a output is shared, so switching between simulator
# and device with unchanged source would skip the rebuild and link the wrong binary.
PLATFORM_MARKER="${PROJECT_DIR}/build/ios/.libhaven_ios_built_platform"
CURRENT_PLATFORM="${PLATFORM_NAME:-iphoneos}"

if [ -f "$HAVEN_LIB_PATH" ] && [ -f "$PLATFORM_MARKER" ]; then
    LAST_PLATFORM=$(cat "$PLATFORM_MARKER")
    if [ "$LAST_PLATFORM" != "$CURRENT_PLATFORM" ]; then
        echo "🔄 Platform changed from $LAST_PLATFORM to $CURRENT_PLATFORM — forcing rebuild."
        rm -f "$HAVEN_LIB_PATH"
    fi
fi

if [ -f "$HAVEN_LIB_PATH" ] && [ -f "$CHECKSUM_FILE" ]; then
    PREVIOUS_CHECKSUM=$(cat "$CHECKSUM_FILE")
    if [ "$CURRENT_CHECKSUM" = "$PREVIOUS_CHECKSUM" ]; then
        echo "✅ Go source unchanged — skipping rebuild."
        exit 0
    fi
fi

# iOS always uses arm64 for device builds
# For simulator, we can use arm64 (Apple Silicon) or x86_64 (Intel)
NEED_ARM64=false
NEED_X86_64=false

# Check if we're building for simulator or device
if [[ "$SDKROOT" == *"simulator"* ]] || [[ "$PLATFORM_NAME" == "iphonesimulator" ]]; then
    echo "📱 Building for iOS Simulator..."
    IS_SIMULATOR=true
    SDK_TAG="iphonesimulator"
    TARGET_SUFFIX="-simulator"
else
    echo "📱 Building for iOS Device..."
    IS_SIMULATOR=false
    SDK_TAG="iphoneos"
    TARGET_SUFFIX=""
fi

# Determine which architectures to build
for arch in $ARCHS; do
    case "$arch" in
        arm64)  NEED_ARM64=true ;;
        x86_64) NEED_X86_64=true ;;
    esac
done

# Fallback to native arch if ARCHS is empty
if ! $NEED_ARM64 && ! $NEED_X86_64; then
    NATIVE=$(uname -m)
    if [ "$NATIVE" == "arm64" ]; then
        NEED_ARM64=true
    else
        NEED_X86_64=true
    fi
fi

# Set up iOS C compiler toolchain using xcrun
export CC=$(xcrun --sdk $SDK_TAG --find clang)
export CXX=$(xcrun --sdk $SDK_TAG --find clang++)
SDK_PATH=$(xcrun --sdk $SDK_TAG --show-sdk-path)

build_for_arch() {
    local goarch=$1
    local label=$2
    local output=$3
    local clang_arch=$2
    
    if [ "$label" == "x86_64" ]; then
        clang_arch="x86_64"
    fi

    echo "🛠️ Building for iOS $label (GOARCH=$goarch) [Simulator: $IS_SIMULATOR]..."
    
    # Use -target for precise control over the build artifact
    local target="$clang_arch-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}${TARGET_SUFFIX}"
    
    export CGO_CFLAGS="-isysroot $SDK_PATH -target $target"
    export CGO_LDFLAGS="-isysroot $SDK_PATH -target $target"
    
    rm -f "$output"
    GOARCH="$goarch" "$GO_BIN" build -mod=mod -tags "cshared libsecp256k1" -buildmode=c-archive -ldflags="-s -w" -o "$output"
    echo "✅ Built iOS $label slice for target $target."
}

# Ensure output directory exists
mkdir -p "${PROJECT_DIR}/build/ios"

if $NEED_ARM64 && $NEED_X86_64; then
    # Universal build — build both slices and combine with lipo
    ARM64_LIB="${PROJECT_DIR}/build/ios/libhaven-arm64.a"
    X86_64_LIB="${PROJECT_DIR}/build/ios/libhaven-x86_64.a"

    build_for_arch arm64 arm64 "$ARM64_LIB"
    build_for_arch amd64 x86_64 "$X86_64_LIB"

    echo "🔗 Creating universal binary with lipo..."
    lipo -create "$ARM64_LIB" "$X86_64_LIB" -output "$HAVEN_LIB_PATH"
    rm -f "$ARM64_LIB" "$X86_64_LIB"
    echo "✅ Successfully built universal libhaven.a for iOS Simulator (arm64 + x86_64)."
elif $NEED_ARM64; then
    build_for_arch arm64 arm64 "$HAVEN_LIB_PATH"
else
    build_for_arch amd64 x86_64 "$HAVEN_LIB_PATH"
fi

# Verify the generated header exists (c-archive produces it alongside the .a)
GENERATED_HEADER="${PROJECT_DIR}/build/ios/libhaven_ios.h"
if [ -f "$GENERATED_HEADER" ]; then
    echo "✅ libhaven_ios.h generated at $GENERATED_HEADER"
else
    echo "⚠️ Warning: libhaven_ios.h not found at $GENERATED_HEADER — bridging header may fail."
fi

# Persist checksum and platform marker so the next build can skip if unchanged
mkdir -p "$(dirname "$CHECKSUM_FILE")"
echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "$CURRENT_PLATFORM" > "$PLATFORM_MARKER"

echo "🎉 iOS build complete!"