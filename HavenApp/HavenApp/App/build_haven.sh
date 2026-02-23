#!/bin/bash

# This script builds the Go 'haven' binary from the root of the project.
# It is intended to be run as an Xcode Run Script phase.

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
HAVEN_LIB_PATH="${PROJECT_DIR}/build/libhaven.a"

echo "🚀 Building Go libhaven.a from source..."
echo "📍 Source root: $GO_SRC_ROOT"
echo "📍 Output path: $HAVEN_LIB_PATH"

export GOOS="darwin"
export CGO_ENABLED=1
# Match the Xcode deployment target to silence linker version warnings
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export CGO_LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

# Xcode uses a minimal PATH — add common Go install locations
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"

GO_BIN=$(which go 2>/dev/null || true)

if [ -z "$GO_BIN" ]; then
    echo "❌ Error: 'go' command not found. Please install Go (https://go.dev/doc/install)."
    exit 1
fi

cd "$GO_SRC_ROOT"

# Determine which architectures to build
# ARCHS may contain "arm64", "x86_64", or "arm64 x86_64"
NEED_ARM64=false
NEED_X86_64=false

for arch in $ARCHS; do
    case "$arch" in
        arm64)  NEED_ARM64=true ;;
        x86_64) NEED_X86_64=true ;;
    esac
done

# Fallback: if ARCHS is empty/unset, build for native arch
if ! $NEED_ARM64 && ! $NEED_X86_64; then
    NATIVE=$(uname -m)
    if [ "$NATIVE" == "arm64" ]; then
        NEED_ARM64=true
    else
        NEED_X86_64=true
    fi
fi

build_for_arch() {
    local goarch=$1
    local label=$2
    local output=$3
    echo "🛠️ Building for $label (GOARCH=$goarch)..."
    rm -f "$output"
    GOARCH="$goarch" "$GO_BIN" build -tags cshared -buildmode=c-archive -ldflags="-s -w" -o "$output"
    echo "✅ Built $label slice."
}

if $NEED_ARM64 && $NEED_X86_64; then
    # Universal build — build both slices and combine with lipo
    ARM64_LIB="${PROJECT_DIR}/build/libhaven-arm64.a"
    X86_64_LIB="${PROJECT_DIR}/build/libhaven-x86_64.a"

    build_for_arch arm64 arm64 "$ARM64_LIB"
    build_for_arch amd64 x86_64 "$X86_64_LIB"

    echo "🔗 Creating universal binary with lipo..."
    lipo -create "$ARM64_LIB" "$X86_64_LIB" -output "$HAVEN_LIB_PATH"
    rm -f "$ARM64_LIB" "$X86_64_LIB"
    echo "✅ Successfully built universal libhaven.a (arm64 + x86_64)."
elif $NEED_ARM64; then
    build_for_arch arm64 arm64 "$HAVEN_LIB_PATH"
    echo "✅ Successfully built libhaven.a for arm64."
else
    build_for_arch amd64 x86_64 "$HAVEN_LIB_PATH"
    echo "✅ Successfully built libhaven.a for x86_64."
fi
