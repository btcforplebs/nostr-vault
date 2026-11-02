#!/bin/bash
# Release gate for the nostr.build GIF key. Xcode Run Script phase, first in the iOS and macOS app targets.
#
# The key reaches Info.plist (NostrBuildGIFAPIKey = $(NOSTR_BUILD_GIF_KEY)) from the gitignored
# Config/Secrets.xcconfig, which Base.xcconfig pulls in with an optional `#include?`. A checkout without that file
# (a fresh worktree, a /tmp copy) builds fine with an empty key, and the app then hides its GIF button
# (GifSource.available is empty). That shipped to TestFlight and to Logen's devices more than once.
#
# Release: no key fails the build. Debug: a warning only.
# Fix: cp ~/haven/HavenApp/Config/Secrets.xcconfig <checkout>/HavenApp/Config/
key="$(printf '%s' "${NOSTR_BUILD_GIF_KEY:-}" | tr -d '[:space:]')"
case "$key" in
  ""|'$('*) ;;
  *) exit 0 ;;
esac
msg="NostrBuildGIFAPIKey is empty: Config/Secrets.xcconfig is missing or has no NOSTR_BUILD_GIF_KEY, so this build would hide the GIF button. Copy it in: cp ~/haven/HavenApp/Config/Secrets.xcconfig HavenApp/Config/"
if [ "${CONFIGURATION:-}" = "Release" ]; then
  echo "error: $msg"
  exit 1
fi
echo "warning: $msg"
