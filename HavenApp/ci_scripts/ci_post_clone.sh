#!/bin/sh
# Xcode Cloud runs this after cloning, before the build.
#
# 1. The "Build Go Library (iOS)" phase needs Go, and Xcode Cloud images
#    don't ship it.
# 2. Config/Secrets.xcconfig is gitignored (the repo is public). Recreate it
#    from the NOSTR_BUILD_GIF_KEY secret environment variable set on the
#    workflow, or the GIF button hides in the build.
set -e

brew install go
go version

if [ -n "$NOSTR_BUILD_GIF_KEY" ]; then
    printf 'NOSTR_BUILD_GIF_KEY = %s\n' "$NOSTR_BUILD_GIF_KEY" \
        > "$CI_PRIMARY_REPOSITORY_PATH/HavenApp/Config/Secrets.xcconfig"
    echo "Secrets.xcconfig written"
else
    echo "warning: NOSTR_BUILD_GIF_KEY not set; GIF picker will be off"
fi
