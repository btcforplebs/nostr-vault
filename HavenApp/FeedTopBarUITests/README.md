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
