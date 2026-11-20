#!/usr/bin/env bash
# build_translate_android.sh
# Build libnvtranslate.so ("Translate post" without Google code) and fetch the
# language-ID model, the same way build_haven_android.sh makes libhaven.so:
# the outputs are gitignored and copied into the app before assembleRelease.
#
#   Bergamot  mozilla/translations inference/ (MPL-2.0), the engine in
#             Firefox Translations. Models are NOT bundled: the app fetches
#             them from Mozilla per language on first use.
#   fastText  facebookresearch/fastText (MIT) + lid.176.ftz (CC BY-SA 3.0),
#             bundled as an asset so language ID works offline.
#
# Prerequisites: git, Android SDK cmake 3.22.1 (has ninja), NDK r27+.
#
# Usage:
#   ./build_translate_android.sh              # fetch pinned sources if needed, build arm64-v8a + armeabi-v7a
#   ./build_translate_android.sh arm64-v8a    # one ABI
#   ./build_translate_android.sh clean        # remove the .so files, the asset, the build dirs and sources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${NV_TRANSLATE_SRC:-$SCRIPT_DIR/.translate-src}"
BUILD_BASE="$SCRIPT_DIR/.translate-build"
JNILIBS="$SCRIPT_DIR/app/src/main/jniLibs"
ALL_ABIS="arm64-v8a armeabi-v7a"
ASSET_OUT="$SCRIPT_DIR/app/src/main/assets/translate/lid.176.ftz"

# Pins. Bump on purpose, then rebuild and run Translate on a device.
MOZ_TRANSLATIONS_COMMIT="8eada038fd45bbf6fa58a412b22f80c79887fabc"   # 2026-10-29
# Bump when patch_bergamot changes, so a cached source export is re-made.
BERGAMOT_PATCHES="2"   # 2 = armeabi-v7a fixes
FASTTEXT_COMMIT="1142dc4c4ecbc19cc16eee5cdd28472e689267e6"           # 2024-03-13 (archived)
LID_URL="https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz"
LID_SHA256="8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83"
# The inference submodules Bergamot needs on arm64 (no CUDA, fbgemm, nccl, emsdk).
SUBMODULES=(
  inference/3rd_party/ssplit-cpp
  inference/marian-fork/src/3rd_party/sentencepiece
  inference/marian-fork/src/3rd_party/ruy
  inference/marian-fork/src/3rd_party/intgemm
  inference/marian-fork/src/3rd_party/simd_utils
  inference/marian-fork/src/3rd_party/onnxjs
)

ABIS="${*:-$ALL_ABIS}"
for abi in $ABIS; do
  case "$abi" in arm64-v8a|armeabi-v7a|clean) ;; *) echo "ERROR: unknown ABI '$abi' ($ALL_ABIS)"; exit 1 ;; esac
done

if [ "${1:-}" = "clean" ]; then
  rm -rf "$SRC" "$BUILD_BASE" "$BUILD_BASE"-* "$ASSET_OUT"
  for abi in $ALL_ABIS; do rm -f "$JNILIBS/$abi/libnvtranslate.so"; done
  echo "Cleaned translate sources, build output, libnvtranslate.so and lid.176.ftz"
  exit 0
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || { echo "ERROR: NDK not found (set ANDROID_NDK_HOME)"; exit 1; }
CMAKE_BIN="$(ls -d "$SDK"/cmake/*/bin 2>/dev/null | sort -V | tail -1 || true)"
[ -x "$CMAKE_BIN/cmake" ] || { echo "ERROR: Android SDK cmake not found (sdkmanager 'cmake;3.22.1')"; exit 1; }
export PATH="$CMAKE_BIN:$PATH"
echo "NDK:   $ANDROID_NDK_HOME"
echo "CMake: $CMAKE_BIN"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# ── Sources ────────────────────────────────────────────────────────────────
fetch_bergamot() {
  local stamp="$SRC/bergamot/.pinned"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$MOZ_TRANSLATIONS_COMMIT+p$BERGAMOT_PATCHES" ]; then return; fi
  echo "Fetching mozilla/translations $MOZ_TRANSLATIONS_COMMIT (inference/ only)..."
  local clone="$SRC/.mozilla-translations"
  # A build dir made from the old export points at files it unpacked there
  # (ssplit's pcre2); start those over too.
  rm -rf "$clone" "$SRC/bergamot" "$BUILD_BASE" "$BUILD_BASE"-*
  mkdir -p "$SRC"
  git clone -q --filter=blob:none --no-checkout --sparse https://github.com/mozilla/translations "$clone"
  git -C "$clone" sparse-checkout set inference
  git -C "$clone" checkout -q "$MOZ_TRANSLATIONS_COMMIT"
  for sub in "${SUBMODULES[@]}"; do
    git -C "$clone" submodule update -q --init --recursive --filter=blob:none "$sub"
  done
  # Export without the parent repo: marian-fork's CMake runs `git submodule
  # update` for whatever repo it sits in (that would pull the whole training
  # tree) and wants a .git three levels up for its revision header.
  mkdir -p "$SRC/bergamot"
  rsync -a --exclude .git "$clone/inference/" "$SRC/bergamot/inference/"
  (cd "$SRC/bergamot" && git init -q && git add -A >/dev/null 2>&1 &&
    git -c user.name=build -c user.email=build@localhost commit -q -m "mozilla/translations $MOZ_TRANSLATIONS_COMMIT inference")
  rm -rf "$clone"
  patch_bergamot
  echo "$MOZ_TRANSLATIONS_COMMIT+p$BERGAMOT_PATCHES" > "$stamp"
}

# Upstream builds natively only for x86 and as WASM. These make it build for
# arm64 with NDK clang 18+; each is a compile fix, not a behaviour change.
patch_bergamot() {
  local inf="$SRC/bergamot/inference"
  # clang 18+: a cast to an enum outside its range is not a constant expression.
  perl -pi -e 's/^  constexpr unicode_script::ScriptType kAnyType =/  const unicode_script::ScriptType kAnyType =/' \
    "$inf/marian-fork/src/3rd_party/sentencepiece/src/trainer_interface.cc"
  # simd_utils uses fesetround/FE_* without including <fenv.h> (CRLF file).
  perl -pi -e 'if (!$done && s/^#include <math.h>(\r?)$/#include <fenv.h>$1\n#include <math.h>$1/) { $done = 1 }' \
    "$inf/marian-fork/src/3rd_party/simd_utils/simd_utils.h"
  # New clang warnings (e.g. -Wvla-cxx-extension) must not fail the build.
  perl -pi -e 's/list\(APPEND ALL_WARNINGS -Wall; -Werror;/list(APPEND ALL_WARNINGS -Wall;/' \
    "$inf/marian-fork/CMakeLists.txt"
  # armeabi-v7a: two compile fixes in simd_utils' 32-bit (non-aarch64)
  # branches. On arm64 __m128d is float64x2_t, so its code is unchanged.
  #   sse2neon _mm_stream_pd names float64x2_t, which 32-bit NEON lacks.
  perl -pi -e 's/__builtin_nontemporal_store\(a, \(float64x2_t \*\) p\)/__builtin_nontemporal_store(a, (__m128d *) p)/' \
    "$inf/marian-fork/src/3rd_party/simd_utils/sse2neon.h"
  #   _mm_cvtpd_epi64's fallback passes int64_t to _mm_set_epi64 (__m64 args).
  perl -pi -e 's/return _mm_set_epi64\(a1, a0\);/return _mm_set_epi64x(a1, a0);/' \
    "$inf/marian-fork/src/3rd_party/simd_utils/sse2neon_wrapper.h"
  grep -q '__builtin_nontemporal_store(a, (__m128d \*) p)' "$inf/marian-fork/src/3rd_party/simd_utils/sse2neon.h"
  grep -q 'return _mm_set_epi64x(a1, a0);' "$inf/marian-fork/src/3rd_party/simd_utils/sse2neon_wrapper.h"
  #   ruy_interface.h quantizes with vcvtnq_s32_f32 (round to nearest), an
  #   ARMv8 instruction. 32-bit NEON rounds to nearest-even by default, so
  #   adding and removing 1.5 * 2^23 rounds the same way; larger values
  #   saturate to int8 right after either way.
  perl -0pi -e 's{(#include <arm_neon.h>\n)}{$1#if !defined(__aarch64__)\nstatic inline int32x4_t nv_vcvtnq_s32_f32(float32x4_t v) {\n  const float32x4_t magic = vdupq_n_f32(12582912.0f);\n  return vcvtq_s32_f32(vsubq_f32(vaddq_f32(v, magic), magic));\n}\n#define vcvtnq_s32_f32 nv_vcvtnq_s32_f32\n#endif\n}' \
    "$inf/marian-fork/src/tensors/cpu/ruy_interface.h"
  grep -q 'nv_vcvtnq_s32_f32' "$inf/marian-fork/src/tensors/cpu/ruy_interface.h"
  # pathie-cpp converts filenames with iconv, which bionic only has from API 28
  # (minSdk is 26). With PATHIE_ASSUME_UTF8_ON_UNIX (set in CMakeLists.txt)
  # it is never called; this compiles it out on Android.
  local pathie="$inf/marian-fork/src/3rd_party/pathie-cpp/src/pathie.cpp"
  perl -0pi -e 's{#include <iconv.h>\n}{#if !defined(__ANDROID__)\n#include <iconv.h>\n#endif\n}' "$pathie"
  perl -0pi -e 's{(const std::string& string\)\n\{\n)}{$1#if defined(__ANDROID__)\n  (void)from_encoding; (void)to_encoding;\n  return string;\n#else\n}' "$pathie"
  perl -0pi -e 's{(  return result;\n)(\}\n\n/\*\*\n \* Converts the given UTF-8 string into the native filename encoding)}{$1#endif\n$2}' "$pathie"
  grep -q 'return string;' "$pathie"
  [ "$(grep -c '__ANDROID__' "$pathie")" = 2 ]
  # Same for glob()/globfree() (API 28); nothing in marian or Bergamot globs.
  local pathcpp="$inf/marian-fork/src/3rd_party/pathie-cpp/src/path.cpp"
  perl -0pi -e 's{(std::vector<Path> Path::glob\(const std::string& pattern, int flags /\* = 0 \*/\)\n\{\n)#if defined\(_PATHIE_UNIX\)\n}{$1#if defined(__ANDROID__)\n  (void)pattern; (void)flags;\n  return std::vector<Path>();\n#elif defined(_PATHIE_UNIX)\n}' "$pathcpp"
  grep -q '#elif defined(_PATHIE_UNIX)' "$pathcpp"
  grep -q 'const unicode_script::ScriptType kAnyType' "$inf/marian-fork/src/3rd_party/sentencepiece/src/trainer_interface.cc"
  grep -q '#include <fenv.h>' "$inf/marian-fork/src/3rd_party/simd_utils/simd_utils.h"
  ! grep -q 'ALL_WARNINGS -Wall; -Werror;' "$inf/marian-fork/CMakeLists.txt"
}

fetch_fasttext() {
  if [ -f "$SRC/fastText/.pinned" ] && [ "$(cat "$SRC/fastText/.pinned")" = "$FASTTEXT_COMMIT" ]; then return; fi
  echo "Fetching fastText $FASTTEXT_COMMIT..."
  rm -rf "$SRC/fastText"
  git clone -q --filter=blob:none https://github.com/facebookresearch/fastText "$SRC/fastText"
  git -C "$SRC/fastText" checkout -q "$FASTTEXT_COMMIT"
  echo "$FASTTEXT_COMMIT" > "$SRC/fastText/.pinned"
}

fetch_lid_model() {
  if [ -f "$ASSET_OUT" ] && [ "$(sha256 "$ASSET_OUT")" = "$LID_SHA256" ]; then return; fi
  echo "Fetching lid.176.ftz..."
  mkdir -p "$(dirname "$ASSET_OUT")"
  curl -fsSL -o "$ASSET_OUT.part" "$LID_URL"
  [ "$(sha256 "$ASSET_OUT.part")" = "$LID_SHA256" ] || { rm -f "$ASSET_OUT.part"; echo "ERROR: lid.176.ftz checksum mismatch"; exit 1; }
  mv "$ASSET_OUT.part" "$ASSET_OUT"
}

fetch_bergamot
fetch_fasttext
fetch_lid_model

# ── Build ──────────────────────────────────────────────────────────────────
build_abi() {
  local abi="$1"
  local build="$BUILD_BASE-$abi"
  local jni_out="$JNILIBS/$abi/libnvtranslate.so"
  cmake -S "$SCRIPT_DIR/translate-native" -B "$build" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$CMAKE_BIN/ninja" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DNV_TRANSLATE_SRC="$SRC" >"$build.cmake.log" 2>&1 || { tail -40 "$build.cmake.log"; exit 1; }
  cmake --build "$build" --target nvtranslate -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

  mkdir -p "$(dirname "$jni_out")"
  "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip --strip-unneeded -o "$jni_out" "$build/libnvtranslate.so"
  rm -f "$build.cmake.log"
  echo "Built $jni_out ($(du -h "$jni_out" | cut -f1)), asset $ASSET_OUT"
}

for abi in $ABIS; do build_abi "$abi"; done
