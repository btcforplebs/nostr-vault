# Agent rules for Nostr Vault

Read this before you plan or edit anything in this repo. It is short on purpose.

## Where things are

| Path | What it is |
|---|---|
| `HavenApp/HavenApp/` | Mac + iOS app (SwiftUI, shared by both targets) |
| `HavenApp/HavenApp-iOS/` | iOS-only shell. `ContentView.swift` is the iOS root; `Views/MenuBarView.swift` is the Mac root |
| `NostrVault/app/src/main/java/com/nostrvault/` | Android app (Kotlin + Compose) |
| `haven-go/` | The relay, compiled into the apps as `libhaven` |
| `fips-bridge/` | Rust networking bridge |
| `.ai-reference/` | Older deep-dive notes (start at `INDEX.md`). Written June 2026: the file paths and line counts there are out of date, the app **does** have tests now, and it does not cover Android. Use it for concepts and check the code before you trust a detail. |

## Code structure rules

The app grew by adding every feature to the nearest big file. In October 2026, 44 files were over 1,000 lines and `FeedView.swift` was over 5,000. These rules stop that from happening again.

1. **File size.**
   - Aim for under **500 lines**.
   - A file over **800 lines** needs a reason.
   - **Never make a file that is already over 1,000 lines bigger.** Put the new code in a new file and call it from the big one. Check with `wc -l <file>` before and after your change. The `File size` PR check (`scripts/check-file-sizes.sh`) fails any PR that breaks this; run it locally with `scripts/check-file-sizes.sh origin/master`.
2. **One screen, one file.** Each SwiftUI `View` / Compose `@Composable` screen, sheet or settings page gets its own file, named after the type: `struct BackupSettingsView` lives in `BackupSettingsView.swift`. Small private helpers that only one screen uses can stay in that screen's file.
3. **Folders by feature.** Put a feature's files in its own folder, for example `Views/Settings/`, `Views/Vault/`, `Views/MediaGallery/`, `Views/Dashboard/`, `Views/SetupWizard/`, and `ui/screens/settings/`, `ui/screens/feed/` on Android. Reusable controls go in `Views/Components/` (Apple) or `ui/components/` (Android).
4. **Services do one job.** A service file covers one responsibility, such as search, snapshots, subscriptions or follow lists. If you are adding a new `// MARK:` section to a service that is already over 1,000 lines, that section should be a new type in a new file.
5. **A new feature means a new file.** Do not add a feature to an existing screen's file just because that screen shows it. Add the feature's own view and embed it.
6. **Apple and Android mirror each other.** The two apps have the same screens with the same names (`FeedService.swift` / `FeedService.kt`, `SettingsView.swift` / `SettingsScreen.kt`). When you split or move one, say in the PR what its twin should become, so the two stay recognisable to each other.
7. **Moves and changes go in separate commits.** A split or move is its own commit that changes no behaviour, so a reviewer can check it line for line. Do not fix bugs or rename things in the same commit.

## Mechanics that bite

- **Xcode project is generated.** `HavenApp/project.yml` is the source of truth and `project.pbxproj` is generated from it. After adding, moving or deleting a Swift file, run `cd HavenApp && xcodegen generate` and commit the regenerated `project.pbxproj`. If you skip this, the file is silently not in the app.
- **Files under `HavenApp/MediaLogicTests/Sources/` are symlinks** into the app. If you move a file that one of them points to, fix the link.
- **iOS-only code (`#if os(iOS)`) is not compiled by a Mac build.** Build the `HavenApp-iOS` scheme too.
- **Android debug installs wipe keys.** Debug and release share an application id with different signing keys, so a debug install over a release one erases the user's keys. Install release builds on real devices.

## Done means on the device

A green build, green tests and an open PR are not "done". Build, install and launch the change on a physical device, look at the change itself, and say which device you checked. If a device is unreachable, report that as a blocker.
