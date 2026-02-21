# Haven App Release Process

This document outlines the step-by-step process for preparing, building, and launching a new version of the Haven App (e.g., releasing `v2.3.0`).

## 1. Update Version Numbers

Before building the release, ensure the version number is updated across the project.

### Xcode Project (`project.pbxproj`)
1. Open `HavenApp/HavenApp.xcodeproj` in Xcode.
2. Select the **HavenApp** target.
3. In the **General** tab, update the **Version** (e.g., `2.3.0`) and the **Build** number.
   - Alternatively, this updates `MARKETING_VERSION` in `project.pbxproj`.

### Release Notes & Changelog
1. **`CHANGELOG.md`**: Add a new section for the upcoming version (e.g., `## [2.3.0] - YYYY-MM-DD`). Move any unreleased changes into this section and group them by `Added`, `Changed`, `Fixed`, etc.
2. **`HavenApp/RELEASE_NOTES.md`**: Update the header to match the new version (e.g., `# Haven App v2.3.0 Release Notes`) and summarize the key changes for this specific release.

---

## 2. Verify and Build the App

The build process involves compiling the Go backend and wrapping it in the Swift macOS app.

1. **Verify the Go Backend (Optional but Recommended)**:
   Ensure the `haven-go` code compiles without errors:
   ```bash
   cd haven-go && go build .
   ```

2. **Build Release Archive in Xcode**:
   1. Open `HavenApp.xcodeproj` in Xcode.
   2. Select the **HavenApp** scheme and set the destination to **Any Mac** (or **My Mac**).
   3. From the menu bar, select **Product > Archive**.
      - *Note*: Xcode automatically runs the `build_haven.sh` script to compile the Go binary for the correct architecture and injects it into the app bundle. It also runs `sign_haven.sh` to codesign the Go binary with the Hardened Runtime.
   4. Once the archive is complete, the Xcode Organizer window will open.

---

## 3. Export and Package the Release

From the Xcode Organizer:

1. Select the new archive and click **Distribute App**.
2. Choose a distribution method (e.g., **Custom** -> **Copy App** or **Direct Distribution** if applicable).
3. Export the `HavenApp.app` file to a known location (e.g., your Desktop).

### Create the ZIP Archive
For distribution (e.g., via GitHub Releases), you need to compress the `.app` bundle:
1. Open Finder, right-click `HavenApp.app`, and select **Compress "HavenApp"**.
2. Rename the resulting zip file to include the version (e.g., `HavenApp-v2.3.0.zip`).
3. (Optional) Generate a checksum for the release:
   ```bash
   shasum -a 256 HavenApp-v2.3.0.zip
   ```

---

## 4. Publish the Release

1. **Commit and Tag**:
   Commit the version bump changes:
   ```bash
   git add .
   git commit -m "Bump version to v2.3.0"
   git tag v2.3.0
   git push origin main --tags
   ```

2. **Create GitHub Release**:
   - Go to your repository's **Releases** page on GitHub and draft a new release.
   - Select the `v2.3.0` tag.
   - Set the title to `Haven App v2.3.0`.
   - Copy the contents of `RELEASE_NOTES.md` or the corresponding section from `CHANGELOG.md` into the release description.
   - Upload the `HavenApp-v2.3.0.zip` file as an asset.
   - Publish the release.

3. **Announce**:
   - Draft a Nostr announcement or share on social media detailing the new version's features and improvements!

---

## 5. TestFlight & App Store Releases

For releases targeting TestFlight or the App Store Sandbox (e.g., using the `c-shared-relay` architecture), follow these additional steps:

1. **Switch Branches**:
   ```bash
   git checkout c-shared-relay
   git merge master # Ensure it has the latest 2.3.0 features
   ```

2. **Tagging**:
   Use a special tag to denote the TestFlight build:
   ```bash
   git tag v2.3.0-tf
   git push origin c-shared-relay --tags
   ```

3. **Xcode Build**:
   Instead of exporting the app directly, use the **Distribute App** > **App Store Connect** option in the Xcode Organizer to upload the build to TestFlight.

4. **GitHub Release (Optional)**:
   If you want testers to be able to download the Sandboxed version directly from GitHub while waiting on TestFlight approval:
   - Create a pre-release on GitHub using the `v2.3.0-tf` tag.
   - Upload the exported `.app` (or `.zip`) as `HavenApp-v2.3.0-Sandbox.zip`.
