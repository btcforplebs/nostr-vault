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

# 16 KB ELF segment alignment, so the bridge loads on 16 KB-page devices
# (Android 15+). NDK r27, AGP 8.7's default, links 4 KB; every other .so in
# the APK is already 16 KB.
target_link_options(nostrvault-jni PRIVATE "-Wl,-z,max-page-size=16384")

# Link JNI bridge against Go library and Android log
target_link_libraries(
    nostrvault-jni
    haven
    log
)
