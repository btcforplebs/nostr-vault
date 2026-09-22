#!/usr/bin/env bash
# Builds libfips_bridge_ffi.a for the iOS platform Xcode is currently targeting.
#
# Mirrors the incrementality approach of the repo's existing build_haven_ios.sh:
# a platform marker forces a rebuild when switching device <-> simulator, since
# the output path is shared while the architectures are not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/build"
MARKER="$OUT_DIR/.built_platform"

# Xcode has a minimal PATH; cargo lives in the user's home.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

PLATFORM="${PLATFORM_NAME:-iphoneos}"
if [ "$PLATFORM" = "iphonesimulator" ]; then
  TARGET="aarch64-apple-ios-sim"
else
  TARGET="aarch64-apple-ios"
fi

mkdir -p "$OUT_DIR"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$TARGET" ] && [ -f "$OUT_DIR/libfips_bridge_ffi.a" ]; then
  # Let cargo decide whether anything actually needs rebuilding.
  :
fi

echo "building fips-bridge-ffi for $TARGET"
cd "$WORKSPACE_DIR"
cargo build --release --target "$TARGET" -p fips-bridge-ffi

cp "$WORKSPACE_DIR/target/$TARGET/release/libfips_bridge_ffi.a" "$OUT_DIR/libfips_bridge_ffi.a"
echo "$TARGET" > "$MARKER"
echo "-> $OUT_DIR/libfips_bridge_ffi.a"
