# libnvtranslate.so: "Translate post" on Android without Google code.
# Mozilla's Bergamot engine (mozilla/translations inference/, MPL-2.0) for
# translation and fastText (MIT) for language ID, behind one JNI bridge.
# Built by ../build_translate_android.sh, which fetches the pinned sources
# into NV_TRANSLATE_SRC; the .so lands in app/src/main/jniLibs like libhaven.
cmake_minimum_required(VERSION 3.22.1)
project(nvtranslate C CXX)

set(NV_TRANSLATE_SRC "" CACHE PATH "Pinned source export made by build_translate_android.sh")
if(NOT EXISTS "${NV_TRANSLATE_SRC}/bergamot/inference/CMakeLists.txt")
  message(FATAL_ERROR "NV_TRANSLATE_SRC has no bergamot/inference; run build_translate_android.sh")
endif()

# Bergamot on ARM (arm64-v8a and armeabi-v7a): ruy for the int8 and float
# GEMMs, no x86 backends.
set(COMPILE_CUDA OFF CACHE BOOL "" FORCE)
set(USE_FBGEMM OFF CACHE BOOL "" FORCE)
set(USE_MKL OFF CACHE BOOL "" FORCE)
set(USE_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(COMPILE_TESTS OFF CACHE BOOL "" FORCE)
set(COMPILE_LIBRARY_ONLY ON CACHE BOOL "" FORCE)
set(SSPLIT_USE_INTERNAL_PCRE2 ON CACHE BOOL "" FORCE)
set(SSPLIT_COMPILE_LIBRARY_ONLY ON CACHE BOOL "" FORCE)
if(ANDROID_ABI STREQUAL "armeabi-v7a")
  set(BUILD_ARCH armv7-a CACHE STRING "" FORCE)
  # neon_mathfun uses vfmaq_f32 (fused multiply-add), which 32-bit NEON only
  # has with VFPv4. Every armv7 core that runs Android 8+ in practice
  # (Cortex-A7/A15/A53/A55 in 32-bit mode) has it; the NDK default is VFPv3.
  add_compile_options(-mfpu=neon-vfpv4)
else()
  set(BUILD_ARCH armv8-a CACHE STRING "" FORCE)
endif()
# marian-fork sets these for its own directory only; Bergamot's sources
# include the same headers and need them too (upstream builds arm64 natively
# only for macOS tests, not for Android).
add_compile_definitions(ARM FMA SSE)
# Android filenames are UTF-8; pathie-cpp then never needs iconv (API 28+).
add_compile_definitions(PATHIE_ASSUME_UTF8_ON_UNIX)
add_subdirectory("${NV_TRANSLATE_SRC}/bergamot/inference" bergamot EXCLUDE_FROM_ALL)

file(GLOB FASTTEXT_SOURCES "${NV_TRANSLATE_SRC}/fastText/src/*.cc")
list(FILTER FASTTEXT_SOURCES EXCLUDE REGEX "/main\\.cc$")

add_library(nvtranslate SHARED NvTranslateJNI.cpp ${FASTTEXT_SOURCES})
target_include_directories(nvtranslate PRIVATE
  "${NV_TRANSLATE_SRC}/fastText/src"
  "${NV_TRANSLATE_SRC}/bergamot/inference/src")
target_link_libraries(nvtranslate PRIVATE bergamot-translator-source log)
set_target_properties(nvtranslate PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
# 16 KB pages (Android 15+), like every other .so in the APK; only the JNI
# entry points are exported.
target_link_options(nvtranslate PRIVATE
  "-Wl,-z,max-page-size=16384"
  "-Wl,--gc-sections"
  "-Wl,--exclude-libs,ALL")
