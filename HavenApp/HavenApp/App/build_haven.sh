#!/bin/bash

# This script builds the Go 'haven' binary from the root of the project.
# It is intended to be run as an Xcode Run Script phase.

set -e

# The Go source is at the root of the workspace (one level up from HavenApp project dir)

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

HAVEN_OUT_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
HAVEN_OUT_PATH="${HAVEN_OUT_DIR}/haven"

echo "🚀 Building Go haven binary from source..."
echo "📍 Source root: $GO_SRC_ROOT"
echo "📍 Output path: $HAVEN_OUT_PATH"

# Ensure output directory exists
mkdir -p "$HAVEN_OUT_DIR"

# Map Xcode architecture to Go architecture
# NATIVE_ARCH_ACTUAL is usually set by Xcode
if [ "$ARCHS" == "arm64" ]; then
    GOARCH="arm64"
elif [ "$ARCHS" == "x86_64" ]; then
    GOARCH="amd64"
else
    # Fallback to native arch
    GOARCH=$(uname -m)
    if [ "$GOARCH" == "x86_64" ]; then GOARCH="amd64"; fi
fi

export GOOS="darwin"
export GOARCH="$GOARCH"
export CGO_ENABLED=1

# Find Go executable (common locations)
GO_BIN=$(which go || echo "/usr/local/go/bin/go")

if ! command -v "$GO_BIN" &> /dev/null; then
    echo "❌ Error: 'go' command not found. Please install Go (https://go.dev/doc/install)."
    exit 1
fi

# Run the build
cd "$GO_SRC_ROOT"
echo "🛠️ Running: go build -v -ldflags=\"-s -w\" -o $HAVEN_OUT_PATH"
"$GO_BIN" build -v -ldflags="-s -w" -o "$HAVEN_OUT_PATH"

if [ $? -eq 0 ]; then
    echo "✅ Successfully built haven binary for $GOARCH."
else
    echo "❌ Failed to build haven binary."
    exit 1
fi
