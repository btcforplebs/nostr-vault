# Release Playbook

Step-by-step instructions for releasing Haven to the App Store (iOS + macOS) and as a GitHub Release (macOS standalone binary).

---

## Prerequisites

- Apple Developer account enrolled in the Apple Developer Program
- App Store Connect access with the app registered (Bundle ID: `com.havenapp.relay`)
- Xcode 15+ with valid signing certificates and provisioning profiles
- `gh` CLI authenticated (`gh auth login`)
- GPG key configured in GitHub repo secrets (for GoReleaser binary signing)

---

## 1. Pre-Release Checklist

- [ ] All target features are merged to `master`
- [ ] `CURRENT_PROJECT_VERSION` bumped in `project.pbxproj` (all 4 occurrences)
- [ ] `MARKETING_VERSION` bumped if needed (all occurrences)
- [ ] `CHANGELOG.md` updated with new section
- [ ] Clean build succeeds for both schemes: **HavenApp** (macOS) and **HavenApp-iOS** (iOS)
- [ ] Test on device / simulator for both platforms
- [ ] Commit and tag: `git tag -a v<version> -m "Build N: description"`
- [ ] Push: `git push origin master --tags`

---

## 2. App Store Release (iOS)

### 2a. Create the Archive

1. Open `HavenApp/HavenApp.xcodeproj` in Xcode
2. Select the **HavenApp-iOS** scheme
3. Set destination to **Any iOS Device (arm64)**
4. **Product > Archive** (Cmd+B won't work -- must use Archive)
5. Wait for the archive to complete (the Organizer window opens automatically)

### 2b. Upload to App Store Connect

1. In the **Organizer** window, select the new archive
2. Click **Distribute App**
3. Choose **App Store Connect** > **Upload**
4. Select signing options:
   - **Automatically manage signing** (recommended)
   - Or manually select your Distribution certificate + App Store provisioning profile
5. Click **Upload**
6. Wait for the upload to complete and processing email from Apple (can take 5-30 min)

### 2c. Submit for Review

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Navigate to **My Apps > Haven**
3. Click the new version (or create one under **+ Version or Platform** if needed)
4. Under **Build**, click **+** and select the uploaded build (appears after processing)
5. Fill in / update:
   - **What's New in This Version** -- paste from CHANGELOG
   - Screenshots (if UI changed)
   - App Review Information (demo account if needed)
6. Click **Submit for Review**

### 2d. TestFlight (Internal/External)

- Internal testers see new builds automatically after processing
- For external testers: go to **TestFlight** tab in App Store Connect, select the build under the external group, and **Submit for Review** (external TestFlight has a lighter review)

---

## 3. App Store Release (macOS)

### 3a. Create the Archive

1. Open `HavenApp/HavenApp.xcodeproj` in Xcode
2. Select the **HavenApp** scheme
3. Set destination to **My Mac**
4. **Product > Archive**
5. Organizer opens when done

### 3b. Choose Distribution Method

You have two options:

**Option A: Mac App Store**
1. In Organizer, click **Distribute App**
2. Choose **App Store Connect** > **Upload**
3. Follow the same signing / upload / review flow as iOS (section 2b-2c above)

**Option B: Direct Distribution (Developer ID)**
1. In Organizer, click **Distribute App**
2. Choose **Developer ID** (or **Direct Distribution** in newer Xcode)
3. Select **Upload** to have Apple notarize it, or **Export** to notarize manually
4. If uploading: wait for notarization email (usually a few minutes)
5. Once notarized, **Export Notarized App** from Organizer to get the `.app` bundle
6. This `.app` can be distributed outside the App Store (e.g., GitHub Releases, website)

### 3c. Notarization (if exporting manually)

```bash
# Zip the .app for notarization
ditto -c -k --keepParent "Haven.app" Haven.zip

# Submit for notarization
xcrun notarytool submit Haven.zip \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

# Staple the notarization ticket to the app
xcrun stapler staple "Haven.app"
```

---

## 4. GitHub Release (macOS Standalone Binary)

The repo has a GitHub Actions workflow at `.github/workflows/release.yml` that triggers on `v*` tags and uses GoReleaser to build standalone relay binaries (not the app bundle). This is for the **Go relay binary**, not the macOS app.

### 4a. Automatic (Go Relay Binary via GoReleaser)

Pushing a tag that matches `v*` automatically triggers the workflow:

```bash
git tag -a v2.4.0-b6 -m "Build 6: Stability and Polish"
git push origin --tags
```

This builds signed binaries for macOS/Linux/Windows and creates a GitHub Release with checksums. Check progress at: `https://github.com/btcforplebs/haven-mac/actions`

### 4b. Manual GitHub Release (macOS .app Bundle)

To attach the notarized macOS `.app` to a GitHub Release:

```bash
# 1. Create a DMG or zip from the notarized .app
hdiutil create -volname "Haven" -srcfolder "Haven.app" -ov Haven.dmg
# or: ditto -c -k --keepParent "Haven.app" Haven-macOS.zip

# 2. Create the release (or add to existing)
gh release create v2.4.0-b6 \
  --title "Build 6: Stability and Polish" \
  --notes-file CHANGELOG_EXCERPT.md \
  Haven.dmg

# Or upload to an existing release
gh release upload v2.4.0-b6 Haven.dmg
```

---

## 5. Post-Release

- [ ] Verify TestFlight build appears for testers
- [ ] Verify GitHub Release assets are downloadable
- [ ] Test fresh install from TestFlight / DMG on a clean machine
- [ ] Update any external links or documentation

---

## Quick Reference: Version Locations

| Field | File | Notes |
|-------|------|-------|
| `MARKETING_VERSION` | `project.pbxproj` | 4 occurrences (Debug/Release x macOS/iOS) |
| `CURRENT_PROJECT_VERSION` | `project.pbxproj` | 4 occurrences -- this is the build number |
| Changelog | `CHANGELOG.md` | Add new section at top |
| Git tag | CLI | Format: `v{MARKETING_VERSION}-b{BUILD}` |

## Signing & Certificates Summary

| Distribution | Certificate Type | Provisioning |
|-------------|-----------------|-------------|
| App Store (iOS) | Apple Distribution | App Store profile |
| App Store (macOS) | Apple Distribution | Mac App Store profile |
| Developer ID (macOS direct) | Developer ID Application | Developer ID profile |
| TestFlight | Apple Distribution | App Store profile (same as App Store) |

## Entitlements Reminder

The app uses these entitlements (`HavenApp/HavenApp/App/HavenApp.entitlements`):
- App Sandbox (required for App Store)
- Network Client + Server (relay listens on port)
- User-selected file read/write (backup/restore)
- Camera access

If distributing outside the App Store via Developer ID, the same entitlements apply but sandbox is optional (though recommended).
