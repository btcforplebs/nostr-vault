#!/usr/bin/env bash
# release_all.sh — build and publish all three Nostr Vault releases:
#   1. Android APK  → Blossom (logen.btcforplebs.com) → Zapstore (zsp publish)
#   2. macOS app    → zip in dist/ → attached to the GitHub release
#   3. iOS app      → archive → TestFlight upload (falls back to Organizer)
# plus the GitHub release (tag v<macVersion>-b<build>, notes from
# HavenApp/RELEASE_NOTES.md, APK + macOS zip attached).
#
# Usage:
#   ./release_all.sh                 # build everything, then confirm each publish step
#   ./release_all.sh --check        # print versions/tooling status and exit
#   ./release_all.sh --skip-publish # build all three, publish nothing
#   ./release_all.sh --skip-ios --skip-macos   # Android-only release
#   ./release_all.sh --yes          # no confirmation prompts (CI / hands-off)
#
# Secrets (never committed) are read from .release.env at the repo root:
#   SIGN_WITH="bunker://..."        # zapstore publish signing (zsp)
#   NAK_AUTH_ARGS="--sec <key>"     # nak blossom upload auth (or --connect bunker://...)
# The Android keystore path/passwords come from NostrVault/local.properties as before.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
XCODE_DIR="$ROOT/HavenApp"
ANDROID_DIR="$ROOT/NostrVault"
BLOSSOM_SERVER="${BLOSSOM_SERVER:-https://logen.btcforplebs.com}"
GITHUB_REPO="btcforplebs/nostr-vault"
# macOS distribution signing. The Xcode archive is Apple Development-signed and
# only runs on the build Mac; see the re-sign block in the macOS stage.
MAC_TEAM_ID="${MAC_TEAM_ID:-525WQ48Y72}"
MAC_SIGN_ID="${MAC_SIGN_ID:-Developer ID Application: LOGAN D DETTY ($MAC_TEAM_ID)}"
MAC_NOTARY_PROFILE="${MAC_NOTARY_PROFILE:-notarytool}"

# ── flags ────────────────────────────────────────────────────────────────────
SKIP_MACOS=0; SKIP_IOS=0; SKIP_ANDROID=0; SKIP_PUBLISH=0; ASSUME_YES=0; CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --skip-macos)   SKIP_MACOS=1 ;;
        --skip-ios)     SKIP_IOS=1 ;;
        --skip-android) SKIP_ANDROID=1 ;;
        --skip-publish) SKIP_PUBLISH=1 ;;
        --yes)          ASSUME_YES=1 ;;
        --check)        CHECK_ONLY=1 ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $arg (see --help)"; exit 1 ;;
    esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*"; exit 1; }

confirm() {
    # confirm "<question>" — returns 0 to proceed. --yes auto-approves.
    [ "$ASSUME_YES" = 1 ] && return 0
    printf '\033[1m%s [y/N] \033[0m' "$1"
    read -r reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ── secrets / env ────────────────────────────────────────────────────────────
if [ -f "$ROOT/.release.env" ]; then
    # shellcheck source=/dev/null
    source "$ROOT/.release.env"
fi

# ── preflight: read versions from all three projects ─────────────────────────
log "Reading versions"

build_setting() { # build_setting <scheme> <SETTING>
    xcodebuild -project "$XCODE_DIR/HavenApp.xcodeproj" -scheme "$1" \
        -showBuildSettings 2>/dev/null | awk -v k="$2" '$1 == k && $2 == "=" {print $3; exit}'
}

MAC_VERSION="$(build_setting HavenApp MARKETING_VERSION)"
MAC_BUILD="$(build_setting HavenApp CURRENT_PROJECT_VERSION)"
IOS_VERSION="$(build_setting HavenApp-iOS MARKETING_VERSION)"
IOS_BUILD="$(build_setting HavenApp-iOS CURRENT_PROJECT_VERSION)"
ANDROID_VERSION="$(grep -m1 'versionName = ' "$ANDROID_DIR/app/build.gradle.kts" | sed -E 's/.*"(.+)".*/\1/')"
ANDROID_CODE="$(grep -m1 'versionCode = ' "$ANDROID_DIR/app/build.gradle.kts" | grep -oE '[0-9]+')"

[ -n "$MAC_VERSION" ] || die "Could not read macOS MARKETING_VERSION"
[ -n "$ANDROID_VERSION" ] || die "Could not read Android versionName"

BUILD="$MAC_BUILD"
TAG="v${MAC_VERSION}-b${BUILD}"
APK_NAME="NostrVault-b${BUILD}-v${ANDROID_VERSION}.apk"

echo "  macOS   : $MAC_VERSION (build $MAC_BUILD)"
echo "  iOS     : $IOS_VERSION (build $IOS_BUILD)"
echo "  Android : $ANDROID_VERSION (versionCode $ANDROID_CODE)"
echo "  Tag     : $TAG"
echo "  APK     : $APK_NAME"

if [ "$MAC_BUILD" != "$IOS_BUILD" ]; then
    warn "macOS build ($MAC_BUILD) and iOS build ($IOS_BUILD) differ — releases are keyed by build number; bump them together."
fi
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    warn "Working tree has uncommitted changes — the release will be built from them."
fi
if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    warn "Tag $TAG already exists — GitHub release step will reuse it."
fi

if [ "$CHECK_ONLY" = 1 ]; then
    log "Tooling"
    for tool in xcodebuild gh zsp nak shasum; do
        if command -v "$tool" >/dev/null; then echo "  ✓ $tool"; else echo "  ✗ $tool (missing)"; fi
    done
    [ -n "${SIGN_WITH:-}" ]     && echo "  ✓ SIGN_WITH set (zapstore signing)"     || echo "  ✗ SIGN_WITH unset — zsp will prompt or fail"
    [ -n "${NAK_AUTH_ARGS:-}" ] && echo "  ✓ NAK_AUTH_ARGS set (blossom upload)"   || echo "  ✗ NAK_AUTH_ARGS unset — Blossom upload will be manual"
    [ -f "$ANDROID_DIR/local.properties" ] && echo "  ✓ local.properties (keystore)" || echo "  ✗ NostrVault/local.properties missing — Android signing will fail"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$MAC_SIGN_ID"; then
        echo "  ✓ $MAC_SIGN_ID"
    else
        echo "  ✗ Developer ID missing — macOS zip would run ONLY on this Mac"
    fi
    if xcrun notarytool history --keychain-profile "$MAC_NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "  ✓ notarytool profile '$MAC_NOTARY_PROFILE'"
    else
        echo "  ✗ no notarytool profile — recipients must clear quarantine by hand"
    fi
    exit 0
fi

confirm "Release build $BUILD as $TAG?" || die "Aborted."
mkdir -p "$DIST"

# ── 1. Android ───────────────────────────────────────────────────────────────
APK_PATH="$DIST/$APK_NAME"
if [ "$SKIP_ANDROID" = 0 ]; then
    log "Android: rebuilding Go relay (.so) and assembling release APK"
    (cd "$ANDROID_DIR" && ./build_haven_android.sh arm64)
    (cd "$ANDROID_DIR" && ./gradlew assembleRelease -q)
    cp "$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk" "$APK_PATH"
    APK_SHA256="$(shasum -a 256 "$APK_PATH" | awk '{print $1}')"
    echo "  APK: $APK_PATH"
    echo "  SHA256: $APK_SHA256"
else
    warn "Skipping Android build"
    APK_SHA256=""
fi

# ── 2. macOS ─────────────────────────────────────────────────────────────────
MAC_ZIP="$DIST/NostrVault-macOS-${MAC_VERSION}-b${BUILD}.zip"
if [ "$SKIP_MACOS" = 0 ]; then
    log "macOS: archiving Nostr Vault.app"
    MAC_ARCHIVE="$DIST/xcarchive/HavenApp-b${BUILD}.xcarchive"
    rm -rf "$MAC_ARCHIVE"
    xcodebuild archive -project "$XCODE_DIR/HavenApp.xcodeproj" -scheme HavenApp \
        -configuration Release -archivePath "$MAC_ARCHIVE" -quiet
    APP_PATH="$(find "$MAC_ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -1)"
    [ -n "$APP_PATH" ] || die "No .app found in macOS archive"

    # The archive is Apple Development-signed and its embedded provisioning
    # profile lists only the build Mac, so AMFI kills it at exec on every other
    # machine — no dialog beyond "can't be opened", and no crash report, because
    # the process never starts. Re-sign with Developer ID and drop the three
    # restricted entitlements (application-identifier, team-identifier,
    # get-task-allow) that require a profile in the first place.
    MAC_STAGE="$DIST/macos-devid"
    rm -rf "$MAC_STAGE"; mkdir -p "$MAC_STAGE"
    ditto "$APP_PATH" "$MAC_STAGE/$(basename "$APP_PATH")"
    SIGNED_APP="$MAC_STAGE/$(basename "$APP_PATH")"
    rm -f "$SIGNED_APP/Contents/embedded.provisionprofile"

    cat > "$MAC_STAGE/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
PLIST

    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$MAC_SIGN_ID"; then
        log "macOS: re-signing with Developer ID for distribution"
        codesign --force --options runtime --timestamp \
            --entitlements "$MAC_STAGE/entitlements.plist" \
            --sign "$MAC_SIGN_ID" "$SIGNED_APP"
        codesign --verify --deep --strict "$SIGNED_APP" || die "Developer ID signature failed to verify"

        # Notarize when credentials exist. Without a stapled ticket the app is
        # REFUSED (not merely prompted) on any Mac where it arrives quarantined
        # — recipients must run `xattr -dr com.apple.quarantine` by hand.
        if xcrun notarytool history --keychain-profile "$MAC_NOTARY_PROFILE" >/dev/null 2>&1; then
            log "macOS: notarizing (this waits on Apple, usually 2-5 min)"
            NOTARY_ZIP="$MAC_STAGE/notarize.zip"
            ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$NOTARY_ZIP"
            if xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$MAC_NOTARY_PROFILE" --wait; then
                xcrun stapler staple "$SIGNED_APP" && echo "  ✓ notarized + stapled"
            else
                warn "Notarization failed — shipping signed but unnotarized."
            fi
            rm -f "$NOTARY_ZIP"
        else
            warn "No '$MAC_NOTARY_PROFILE' notarytool profile — shipping unnotarized."
            warn "Recipients must run: xattr -dr com.apple.quarantine '/Applications/$(basename "$APP_PATH")'"
            warn "Set up once: xcrun notarytool store-credentials $MAC_NOTARY_PROFILE --apple-id <id> --team-id $MAC_TEAM_ID --password <app-specific>"
        fi
        APP_PATH="$SIGNED_APP"
    else
        warn "No '$MAC_SIGN_ID' in the keychain — shipping the Apple Development archive."
        warn "That build runs ONLY on this Mac (its profile lists this machine alone)."
    fi

    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$MAC_ZIP"
    echo "  Zip: $MAC_ZIP"
    spctl -a -vvv -t exec "$APP_PATH" 2>&1 | sed 's/^/  gatekeeper: /' || true
else
    warn "Skipping macOS build"
fi

# ── 3. iOS ───────────────────────────────────────────────────────────────────
IOS_ARCHIVE="$DIST/xcarchive/HavenApp-iOS-b${BUILD}.xcarchive"
if [ "$SKIP_IOS" = 0 ]; then
    log "iOS: archiving HavenApp-iOS"
    rm -rf "$IOS_ARCHIVE"
    # APPSTORE leaves out GIF sources read from a website without the
    # service's permission (getyarn, Tenor's search page) -- see GifSource.available.
    xcodebuild archive -project "$XCODE_DIR/HavenApp.xcodeproj" -scheme HavenApp-iOS \
        -configuration Release -destination 'generic/platform=iOS' \
        -archivePath "$IOS_ARCHIVE" -allowProvisioningUpdates -quiet \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'
    echo "  Archive: $IOS_ARCHIVE"
else
    warn "Skipping iOS build"
fi

if [ "$SKIP_PUBLISH" = 1 ]; then
    log "Build-only run complete (--skip-publish). Artifacts are in dist/."
    exit 0
fi

# ── 4. Publish: APK → Blossom ────────────────────────────────────────────────
if [ "$SKIP_ANDROID" = 0 ]; then
    ASSET_URL="$BLOSSOM_SERVER/$APK_SHA256.apk"
    log "Blossom: uploading APK to $BLOSSOM_SERVER"
    if curl -sfI "$ASSET_URL" >/dev/null 2>&1; then
        echo "  Already on the server: $ASSET_URL"
    elif [ -n "${NAK_AUTH_ARGS:-}" ] && confirm "Upload $APK_NAME to $BLOSSOM_SERVER?"; then
        # shellcheck disable=SC2086
        nak blossom upload $NAK_AUTH_ARGS --server "$BLOSSOM_SERVER" "$APK_PATH"
        curl -sfI "$ASSET_URL" >/dev/null || die "Upload finished but $ASSET_URL is not serving — check the server."
        echo "  Live: $ASSET_URL"
    else
        warn "NAK_AUTH_ARGS not set (or declined) — upload the APK manually, e.g. via the Mac app's media gallery."
        warn "It must end up at: $ASSET_URL"
        confirm "Continue once the APK is uploaded (curl check will verify)?" || die "Aborted."
        curl -sfI "$ASSET_URL" >/dev/null || die "$ASSET_URL is not serving yet."
    fi

    # ── 5. Publish: Zapstore ─────────────────────────────────────────────────
    log "Zapstore: updating zapstore.yaml and publishing"
    sed -i '' -E \
        -e "s|(source_url: https://github.com/$GITHUB_REPO/tree/).*|\1$TAG|" \
        -e "s|(  asset_url: ).*|\1$ASSET_URL|" \
        "$ANDROID_DIR/zapstore.yaml"
    echo "  zapstore.yaml → tag $TAG, asset $ASSET_URL"
    if confirm "Run zsp publish (signs + publishes the release event)?"; then
        [ -n "${SIGN_WITH:-}" ] || warn "SIGN_WITH not set — zsp will prompt for signing."
        (cd "$ANDROID_DIR" && zsp publish zapstore.yaml)
    else
        warn "Skipped zsp publish — run later: cd NostrVault && zsp publish zapstore.yaml"
    fi
fi

# ── 6. Publish: GitHub release ───────────────────────────────────────────────
log "GitHub: tag + release $TAG"
if confirm "Create/push tag $TAG and GitHub release with notes + artifacts?"; then
    git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 || git -C "$ROOT" tag "$TAG"
    git -C "$ROOT" push origin "$TAG"
    ASSETS=()
    [ -f "$APK_PATH" ] && ASSETS+=("$APK_PATH")
    [ -f "$MAC_ZIP" ] && ASSETS+=("$MAC_ZIP")
    if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        warn "Release $TAG exists — uploading assets with --clobber."
        [ ${#ASSETS[@]} -gt 0 ] && gh release upload "$TAG" "${ASSETS[@]}" --repo "$GITHUB_REPO" --clobber
    else
        gh release create "$TAG" "${ASSETS[@]}" --repo "$GITHUB_REPO" \
            --title "Nostr Vault — Build $BUILD" \
            --notes-file "$XCODE_DIR/RELEASE_NOTES.md"
    fi
    echo "  https://github.com/$GITHUB_REPO/releases/tag/$TAG"
else
    warn "Skipped GitHub release."
fi

# ── 7. Publish: TestFlight ───────────────────────────────────────────────────
if [ "$SKIP_IOS" = 0 ]; then
    log "TestFlight: exporting + uploading iOS build"
    if confirm "Attempt TestFlight upload via xcodebuild (needs Xcode account/cloud signing)?"; then
        EXPORT_PLIST="$DIST/ExportOptions-ios-upload.plist"
        cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
        if xcodebuild -exportArchive -archivePath "$IOS_ARCHIVE" \
            -exportOptionsPlist "$EXPORT_PLIST" -allowProvisioningUpdates; then
            echo "  Uploaded to App Store Connect — check TestFlight processing."
        else
            warn "CLI upload failed — open the archive in Xcode Organizer and distribute from there:"
            warn "  open '$IOS_ARCHIVE'"
        fi
    else
        warn "Skipped. Upload later via Organizer: open '$IOS_ARCHIVE'"
    fi
fi

log "Done. Artifacts in dist/ — remember to commit the zapstore.yaml change."
