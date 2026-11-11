# Feed top bar UI test (iPhone)

Checks that the feed's top pills sit on the screen edges on every feed type,
open and folded (scrolled): the feed picker on the left, the filter pill (or
the lone layout circle, folded) on the right. Logen 2026-11-08: the right
pill landed about 3/4 across on some feeds while it lived in the system
navigation bar's trailing slot.

The app has no test bundle, so this is its own small project that drives the
installed app by bundle id.

```sh
# 1. Build the app for a simulator and install it (one sim, delete it after).
SIM=$(xcrun simctl create feed-topbar com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl boot $SIM
xcodebuild -project HavenApp/HavenApp.xcodeproj -scheme HavenApp-iOS \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath /tmp/topbar-dd build
xcrun simctl install $SIM /tmp/topbar-dd/Build/Products/Debug-iphonesimulator/HavenApp-iOS.app

# 2. Run the test (xcodegen makes the project from project.yml).
cd HavenApp/FeedTopBarUITests && xcodegen generate
xcodebuild test -project FeedTopBarUITests.xcodeproj -scheme UIT \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath /tmp/topbar-uit-dd

xcrun simctl delete $SIM
```

A fresh install is set up read-only with a public npub (no key: nothing can
be posted). Override it with `TEST_RUNNER_TOPBAR_NPUB`. Screenshots of each
state go to `TEST_RUNNER_TOPBAR_SHOTS` when set, and `TEST_RUNNER_TOPBAR_FEEDS`
(comma separated, e.g. `Following,Catch Up`) checks only those feeds.

## End-of-list footer (iPhone + Mac)

`FeedEndOfListTests` (iPhone, scheme `UIT`) checks the footer under the last
note of Popular and that it never draws on Home (Following). Popular can be
slow to fill on a fresh sim, so the test keeps reopening it for up to 15
minutes. (Not Underrated: it needs the trust graph and can stay empty on a
read-only sim, which correctly shows its empty state and no footer.) Run it alone with `-only-testing:UIT/FeedEndOfListTests`.

`FeedEndOfListMacTests` (scheme `UITMac`) is its Mac twin. It needs Automation
Mode (`automationmodetool`, asks for an admin password once) and a Mac app
already set up with a TEST account: a Mac app's data lives in its container,
so never run it on a Mac that holds a real account. Point it at another
build with `TEST_RUNNER_MAC_APP_BUNDLE_ID`.

```sh
xcodebuild test -project FeedTopBarUITests.xcodeproj -scheme UITMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/feed-uit-mac-dd
```
