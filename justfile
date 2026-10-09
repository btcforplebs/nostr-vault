# Haven / Nostr Vault build recipes

android_sdk := env("ANDROID_HOME", env("HOME", "") + "/Library/Android/sdk")
adb := android_sdk + "/platform-tools/adb"
ndk_home := `ls -d ~/Library/Android/sdk/ndk/* 2>/dev/null | tail -1`

# Build Android release APK (compiles Go native lib + Gradle build)
android-build:
    #!/usr/bin/env bash
    set -euo pipefail
    NDK_BIN="{{ndk_home}}/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    GO_SRC="{{justfile_directory()}}/haven-go"
    JNILIBS="{{justfile_directory()}}/NostrVault/app/src/main/jniLibs"
    JNI_SRC="{{justfile_directory()}}/NostrVault/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c"
    # Every ABI the APK ships, from the same Go source. Building only arm64
    # left armv7 / x86_64 phones on months-old Go core code.
    cp "$JNI_SRC" "$GO_SRC/HavenBridgeJNI.c"
    trap 'rm -f "$GO_SRC/HavenBridgeJNI.c"' EXIT
    cd "$GO_SRC"
    for spec in "arm64-v8a arm64 aarch64-linux-android26-clang" \
                "armeabi-v7a arm armv7a-linux-androideabi26-clang" \
                "x86_64 amd64 x86_64-linux-android26-clang"; do
        set -- $spec
        echo "Building libhaven.so for $1 (with JNI bridge)..."
        mkdir -p "$JNILIBS/$1"
        CGO_ENABLED=1 GOOS=android GOARCH=$2 GOARM=7 \
            CC="${NDK_BIN}/$3" \
            CGO_CFLAGS="-DMDB_USE_ROBUST=0" \
            go build -buildmode=c-shared -tags cshared -trimpath \
            -ldflags="-s -w" \
            -o "$JNILIBS/$1/libhaven.so" .
        rm -f "$JNILIBS/$1/libhaven.h"
    done
    echo "Building APK..."
    cd {{justfile_directory()}}/NostrVault && ./gradlew assembleRelease

# Install Android release APK on connected device
android-install:
    {{adb}} install -r {{justfile_directory()}}/NostrVault/app/build/outputs/apk/release/app-release.apk

# Check the committed .xcodeproj against what project.yml would generate:
# which files each has, and which target actually builds them.
# Run before merging a branch that regenerated the project — xcodegen drops
# anything the yml does not name, and the build stays green when it does.
check-project:
    {{justfile_directory()}}/scripts/check-project-sync.sh

# Build iOS app via Xcode
ios-build:
    xcodebuild -project {{justfile_directory()}}/HavenApp/HavenApp.xcodeproj \
        -scheme HavenApp-iOS \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates \
        build

# Build macOS app via Xcode
macos-build:
    xcodebuild -project {{justfile_directory()}}/HavenApp/HavenApp.xcodeproj \
        -scheme HavenApp \
        -configuration Debug \
        -allowProvisioningUpdates \
        build
