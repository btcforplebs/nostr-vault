cmake_minimum_required(VERSION 3.22.1)
project("nostrvault-jni")

# Build the JNI bridge that connects Kotlin -> Go C exports
add_library(
    nostrvault-jni
    SHARED
    java/com/nostrvault/relay/HavenBridgeJNI.c
)

# Link against the pre-built Go relay .so
add_library(haven SHARED IMPORTED)
set_target_properties(haven PROPERTIES
    IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/jniLibs/${ANDROID_ABI}/libhaven.so
    IMPORTED_NO_SONAME TRUE
)

# Link JNI bridge against Go library and Android log
target_link_libraries(
    nostrvault-jni
    haven
    log
)

# ---- FIPS mesh bridge (Rust) ----
#
# Same shape as above: a JNI shim linked against a pre-built .so. The Rust
# artifact is produced by NostrVault/build_fips_android.sh and, like
# libhaven.so, is gitignored — so this is conditional. A checkout without it
# still builds; the app then reports the mesh as unavailable rather than
# failing to link. Do not make this unconditional without also making the
# release build depend on the Rust cross-compile.
set(FIPS_LIB ${CMAKE_SOURCE_DIR}/jniLibs/${ANDROID_ABI}/libfips_bridge_ffi.so)

if(EXISTS ${FIPS_LIB})
    add_library(fips_bridge_ffi SHARED IMPORTED)
    set_target_properties(fips_bridge_ffi PROPERTIES
        IMPORTED_LOCATION ${FIPS_LIB}
        IMPORTED_NO_SONAME TRUE
    )

    add_library(
        fips-bridge-jni
        SHARED
        java/com/nostrvault/fips/FipsBridgeJNI.c
    )

    target_link_libraries(
        fips-bridge-jni
        fips_bridge_ffi
        log
    )
else()
    message(WARNING
        "libfips_bridge_ffi.so missing for ${ANDROID_ABI}; the FIPS mesh will be "
        "unavailable in this build. Run NostrVault/build_fips_android.sh.")
endif()
