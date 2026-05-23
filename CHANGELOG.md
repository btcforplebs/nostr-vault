# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.5.0 MacOS / 1.1 iOS (Build 3)] - 2026-05-23

### Added
- **Bitcoin Taproot Address Derivation**: Implemented native BIP-341 key-path-only Taproot (P2TR) address derivation from the user's Nostr secp256k1 public key in `haven-go/bitcoin.go`. Uses `btcsuite/btcd` for all cryptographic operations — no external process required.
- **Bitcoin Sweep with On-chain PSBT**: Full Bitcoin sweep flow backed by the Go relay: fetches UTXOs from a self-hosted Mempool instance, constructs and signs a raw Taproot transaction via Schnorr signatures, and broadcasts it over the relay's HTTP bridge. The sweep uses key-path spending (BIP-341 `tapTweakHash`) for minimal transaction weight.
- **Bitcoin Sweep Disclaimer View**: Added `BitcoinSweepDisclaimerView` — a pre-sweep confirmation sheet that loads the wallet's spendable balance live from the Mempool API before the user can proceed, with a loading indicator and error state for failed fetches.
- **Bitcoin Price Service**: New `PriceService.swift` singleton that fetches the live BTC/USD spot price from the Mempool API and exposes it app-wide, used to display fiat-equivalent values in the sweep flow and elsewhere.
- **On-chain Zap Display**: Added `OnchainZapDisplay.swift` — a dedicated component for rendering on-chain (Taproot) zap receipts in the note detail and profile views, alongside existing Lightning zap display.
- **Search Tab (MacOS)**: Added a full **Search** tab to the MacOS Menu Bar sidebar, backed by `SearchView` — a multi-source search UI supporting users, notes, links, and hashtags, with a segmented source filter (`All / Haven Relay / Network`).
- **My Profile Quick-Access (MacOS)**: The MacOS sidebar footer now renders the owner's avatar using `AvatarView`, tapping it opens `ProfileView` in a sheet without navigating away from the current tab.
- **Emoji Picker Component**: Extracted a reusable `EmojiPickerView` component (available in both `Views/` and `Views/Components/`) for use in `ComposeView` and replies, with category tabs and search.
- **Feed Media View Component**: Extracted `FeedMediaView` into a standalone component under `Views/Components/` for better code reuse across the feed and note detail.
- **Autoload New Posts Toggle**: Added a `bolt.circle` / `bolt.circle.fill` toolbar button in the iOS Feed toolbar to toggle `autoLoadNewPosts` on/off without entering Settings.
- **Repost Toggle**: Added a dedicated `arrow.2.squarepath` toolbar button in the iOS Feed toolbar to quickly show/hide reposts inline.
- **Go Module: Bitcoin Dependencies**: Added `btcsuite/btcd`, `btcsuite/btcutil`, and `decred/dcrd/dcrec/secp256k1` to `haven-go/go.mod` / `go.sum` for the on-chain transaction layer.
- **C-Shared Bridge Export**: Exported the Bitcoin sweep and address derivation functions via `haven-go/cshared.go` so they are callable from Swift through the embedded `libhaven.a` bridge.
- **@mention Tagging in Compose**: Typing `@` while drafting a note now shows a live-filtered popup of followed users. Selecting a person inserts their `nostr:npub1…` mention token into the note body and automatically adds the corresponding `p` tag to the published event for proper Nostr mention routing.
- **NIP-89 App Handler Client Tagging**: Implemented automatic NIP-89 client identification tagging by default for all signed and published Nostr events. The tag dynamically identifies the target environment, tagging as `"Nostr Vault on iPadOS"` on iPadOS, `"Nostr Vault on iOS"` on iOS, and `"Nostr Vault on MacOS"` on MacOS.
- **Bidirectional Nostr Mute List Syncing (Kind 10000)**: Fully integrated Nostr Kind 10000 (Mute List) events. The app automatically fetches and merges remote mute lists on startup or profile fetch, and publishes signed Kind 10000 events to relays when blocking or unblocking an npub.
- **Per-Account Block Lists**: Replaced the global blacklisted npubs list with a namespaced dictionary `blockedNpubsPerAccount` in `HavenConfig` to track block lists individually per active profile.
- **Unified Blocked Accounts Settings Pane**: Added a new "Blocked" settings tab (`BlockedSettingsView`) displaying profile details, avatars, and search-to-block functionality for the active browsing account.
- **Natural Aspect-Preserving Media Layouts**: Replaced rigid and square/letterboxed constraints for photos and GIFs in `FeedMediaView` with high-fidelity, aspect-aware bounds (`.aspectRatio(contentMode: .fit)`).
- **Dual Landscape/Portrait Sizing Model**: Introduced an adaptive dual-height cap (`maxHeight: 400` / `portraitMaxHeight: 600`) so that portrait media can fill the available horizontal width naturally, while limiting extremely tall images to prevent feed drowning.
- **Dedicated Sub-components for Media Rendering**: Refactored `FeedMediaView` to use isolated `FeedPhotoView` and `FeedGIFView` helpers, streamlining asynchronous loading, animation state, and layout calculations.
- **Countdown Timers for User Actions**: Implemented dual countdown timers for both post creation and reposting. When a post is created, a 10-second countdown appears below it labeled "Post created - editing in Xs", giving users a window to edit or delete. When reposting, a 5-second countdown displays "Reposting in Xs" before the action is confirmed.
- **Repost Icon Status Indicator**: The repost button (`arrow.2.squarepath`) now lights up green with a subtle scale animation when a post has been reposted, providing visual feedback similar to the liked heart icon. Tracked via new `repostedEventIds: Set<String>` in `FeedService`.
- **iOS Floating "Liquid Glass" Tab Bar**: Replaced the native system bottom tab bar on iOS with a premium, floating "Liquid Glass" tab bar featuring a rounded capsule design, `.ultraThinMaterial` blur background, a soft drop shadow, a white reflective gradient stroke overlay, and spring scale micro-animations for active buttons.
- **Dynamic Profile Tab Avatar**: Upgraded the Profile navigation tab on iOS to display the active account's custom `AvatarView` instead of a static vector icon, dynamically updating in real-time when switching accounts.
- **Tab Bar Profile Fast-Switching**: Integrated the multi-account selector into a hold (context menu) gesture directly on the bottom bar's Profile tab item, enabling effortless account switching from anywhere in the app.
- **Real-Time Feed Reloading on Account Switch**: Configured `FeedService` to observe active Nostr identity shifts, automatically clearing feed caches, resetting relay subscriptions, and fetching the contact list for the newly selected account to refresh the following feed instantly.
- **App Renamed to Nostr Vault**: Completed front-facing rename from Haven to Nostr Vault. Updated `PRODUCT_NAME` in Xcode build settings (Debug + Release), all user-visible strings in `MenuBarView` ("Quit Nostr Vault", stale-process error, "Nostr Vault Relay" search tab label), the backup restore description in `SettingsView`, and both iOS privacy permission strings in `HavenApp-iOS/Info.plist`. Internal Go codebase, bundle identifiers, and Swift type names are unchanged.
- **iOS Note Detail Text Wrapping & Font Size Fix**: Resolved a visual layout bug on iOS where the parsed markdown text inside `NoteDetailView` would scale excessively large under custom Dynamic Type profiles and overflow the screen boundaries horizontally. Fixed by locking the system font size to a highly readable 16 pt with standard color/spacing, and applying `.fixedSize(horizontal: false, vertical: true)` to ensure correct text wrapping behavior within dynamic SwiftUI scroll containers.
- **macOS Video Opacity**: Fixed videos appearing transparent/see-through on macOS by setting `isOpaque = true` on the AVPlayerLayer backing layer in `InlinePlayerLayer`.
- **Blossom Storage Breakdown**: Added an interactive breakdown modal in the Dashboard that categorizes stored blobs by media type (Images, Videos, Audio, Other), showing both count and storage size per category.

### Changed
- **Bitcoin Sweep Refactored into Disclaimer+Action Pattern**: Replaced the old `BitcoinSweepView` with a two-step flow — `BitcoinSweepDisclaimerView` (balance confirmation) leading to the sweep action — triggered as a sheet from `SettingsView`. Removed all deprecated `BitcoinSweepView.swift` duplicates (`Views/`, `Views/Components/`, `HavenApp/` root).
- **Feed Toolbar Reorganized (iOS)**: The leading toolbar area now shows only the connection-status dot (enlarged to 12 pt, backed by a subtle circular background). The feed mode selector (`FeedMode` menu) was promoted to the `principal` (center) position for better visual hierarchy. The trailing area now hosts the autoload and repost toggles.
- **Connection Status Dot Elevated**: Connection dot now renders at 12 × 12 pt with an 80 % opacity shadow and a `Color.primary.opacity(0.08)` circular background, making it more legible on all backgrounds.
- **Consistent Dark Theme Colors**: Background colors across FeedView, MenuBarView, ProfileView, and relay status pages are now unified to `Color(red: 0.08, green: 0.08, blue: 0.1)` — eliminating visual inconsistency between sections.
- **ZapService Refactored**: Streamlined `ZapService.swift` (~100-line reduction), consolidating redundant payment-path branches and improving error propagation to the `ZapNotificationBanner`.
- **FeedService Major Overhaul**: Significant rewrite of `FeedService.swift` (308-line net change) improving subscription lifecycle management, deduplication, and engagement-stat flushing performance.
- **BlossomService Cleanup**: Tightened upload/download path resolution and improved local vs. remote URL detection in `BlossomService.swift`.
- **AnimatedImage Refactored**: Updated `AnimatedImage.swift` to use the new `FeedMediaView` component and improved GIF frame-timing logic to fix extra spacing that appeared above GIF content.
- **ComposeView Enriched**: `ComposeView.swift` gained emoji-picker integration, improved attachment preview layout, and reply context display.
- **NoteDetailView Improvements**: Enriched reply threading, added on-chain zap display, and improved real-time reply subscription handling.
- **ProfileView Overhaul**: Major refactor (~768 → full rewrite) with improved tab structure, zap/like history sections, and consistent dark background.
- **VideoPlayerView Enhanced**: Improved seek-bar behavior, playback state management, and extensionless file handling in `VideoPlayerView.swift`.
- **FeedMediaViewer Enhancements**: Improved swipe-to-dismiss gesture sensitivity and background dimming ramp in `FeedMediaViewer.swift`.
- **ViewerView Polished**: Cleaned up filter/tab transitions and improved Likes/Zaps sub-tab scroll behavior.
- **iOS ContentView (iPad)**: Minor layout fixes in `HavenApp-iOS/ContentView.swift` for sidebar state propagation.
- **HavenConfig Model Extended**: Added `autoLoadNewPosts` and `showReposts` boolean fields to `HavenConfig.swift` for the new toolbar toggles.
- **MediaItem Model**: Minor additions to `MediaItem.swift` for improved MIME / source tagging.
- **FeedProfile Model**: Small additions to `FeedProfile.swift` for search result rendering.
- **Settings UI Consolidation**: Merged "Identity" and "Access Control" configuration tabs into a single unified "Accounts" settings pane (`AccountsSettingsView`).
- **Implicit Account Whitelisting**: Added accounts (primary and secondary) are now implicitly whitelisted, eliminating the manual whitelisting step.
- **Primary Owner Block Sync to Relay**: Configured the primary Owner's personal block list to sync directly to the Go relay's `blacklisted_npubs.json` file for backend connection-level rejection.
- **Proactive Background Nostr Prefetching**: Overhauled threading performance by triggering asynchronous parent and quote note prefetching inside `FeedService.handleFeedMsgBackground`. Missing notes are fetched on background message processing immediately after events are parsed, dramatically speeding up scrolling loads for deep conversation trees.
- **NIP-45 COUNT Query Integration**: Refactored the relay event-counting mechanism in `NostrService` to use NIP-45 `COUNT` queries instead of `REQ` subscriptions. This resolves the issue where server-enforced event limit caps on standard subscriptions caused incorrect and capped event counts.
- **Unified Total Relay Events Stat**: Consolidated notes and reactions tracking on the dashboard into a single, comprehensive "Total Relay Events" metric, querying all event types with an empty filter payload.
- **Profile Switching UX**: Fixed unnecessary "Restart Required" banner that appeared when switching between profiles/accounts. The `activeAccountNpub` field is now excluded from the relay restart check, as it's an app-level preference, not a relay configuration change.
- **iOS Feed Header Cleanup**: Removed the legacy profile switcher dropdown from the top-left toolbar of the iOS feed view, leaving the connection status dot as a cleaner, dedicated indicator.
- **Improved Likes/Zaps Loading States**: Enhanced ViewerView with debounced settle states (1.5s) for likes and zaps lists to prevent spinner flashing during real-time updates. Prevents unnecessary UI thrashing when content has already been displayed.

### Fixed
- **GIF Spacing Bug**: Resolved unintended top padding above GIF content in `FeedNoteRow` / `feedMediaCarousel` by correcting the `AnimatedImage` frame modifier chain.
- **Bitcoin Sweep Balance Showing Zero**: Fixed `BitcoinSweepDisclaimerView` to correctly await the async Mempool balance fetch before rendering, so the displayed `balanceSats` is never stale.
- **Search Bar Keyboard Dismissal**: Added `@FocusState` management to the viewer/search inputs so tapping the list or the ✕ clear button properly dismisses the keyboard.
- **ZapNotifier Relay Integration**: Fixed `ZapNotificationBanner` to properly subscribe to the Haven relay's WebSocket for incoming zap receipts and update pill state (`Zapping… → Zapped! / Zap failed`) in real-time.
- **Carousel Image Swiping**: Fixed swipe gesture recognizer conflict in `FeedMediaView` carousels so horizontal swipes page between images without accidentally triggering vertical scroll.
- **Goofy Thread Spacing & Vertical Line Stretching**: Fixed a severe visual bug in `FeedView` / `FeedNoteRow` where reply rows containing photos or GIFs would stretch vertical layout boundaries and the thread connector line. Enforced rigid thread sizing (`width: 2, height: 14`) and applied `.fixedSize(horizontal: false, vertical: true)` on nested thread rows to ensure layout integrity.
- **LNURL Resolution for LUD-16 Addresses**: Fixed incorrect fallback that used a profile's NIP-05 identifier as a Lightning address when `lud16` was absent. NIP-05 and LUD-16 share the same `user@domain.com` format but resolve to completely different endpoints — this caused silent zap failures for any account whose NIP-05 domain doesn't also serve LNURL-pay.
- **LUD-06 (Raw LNURL) Zap Support**: Accounts that publish a raw bech32 `lnurl1…` string in the `lud06` metadata field (instead of a LUD-16 address) can now be zapped. `FeedProfile` stores `lud06`, `NostrService` parses it from Kind 0 metadata, and `LNURLService` decodes the bech32 payload to recover the HTTPS pay endpoint without a DNS lookup.
- **MacOS Compilation Fixes**: Resolved MacOS build errors by replacing unsupported `.tabViewStyle(.page(...))` with `.mediaTabViewStyleCompat()` in `NoteDetailView` and `FeedView`, and wrapping the iOS-only `.navigationBarTitleDisplayMode(.inline)` modifier in a platform-check preprocessor macro inside `BitcoinSweepDisclaimerView`.

## [2.4.0 macOS / 1.0 iOS (Build 7)] - 2026-05-19

### Added
- **Accent Theme Customization**: Introduced `AppTheme` enum with 6 preset accent colors (Haven Purple, Ocean Blue, Emerald Green, Sunset Orange, Rose Pink, Monochrome Slate) and added a dedicated "Appearance" Settings Tab supporting full dynamic theme-switching across iOS and macOS.
- **Universal iOS & iPad Layouts**: Integrated size-class checking (`@Environment(\.horizontalSizeClass)`) in the iOS ContentView to offer a professional sidebar-driven `iPadSidebarView` using `NavigationSplitView` alongside the standard tab-based layout for iPhone.
- **Engagement Feed Stats**: Enhanced `FeedService` to track, parse, and aggregate real-time engagement statistics (likes, replies, reposts) in background flushes, updating notes efficiently with real-time feedback.
- **Community Interaction Tabs (Likes & Zaps)**: Overhauled `ViewerView` with dedicated sub-tabs for "Likes" and "Zaps", enabling users to browse notes they liked/zapped, or see which of their own notes were zapped/liked, with beautiful stacked overlapping zapper/reactor avatars and satoshi totals.
- **Interactive Zap Notifications**: Built a floating `ZapNotificationBanner` overlay featuring animated, state-aware status pills (`ZapPill`) showing real-time feedback (Zapping..., Zapped!, Zap failed) with a pulsing lightning bolt.
- **Network Media Sync & Progress**: Enhanced the "Restore Media" wizard step to support segmented selection of either network sync from a remote Blossom server or local ZIP import, including a progress bar indicator during external Blossom media mirroring.

### Changed
- **Unified Feed Navigation**: Promoted the "Feed" view to the primary tab/view in both the Menu Bar and the iOS/iPad app, replacing the technical "Dashboard" tab as the central user workspace.
- **On-the-Fly Feed Controls**: Added interactive dropdown selectors to switch FeedModes (e.g. Following vs Global) directly from the iOS Navigation Bar and the macOS Menu Bar.
- **Smart Repost Fetching**: Added support for fetching parent/original note contents automatically for empty-content reposts.

## [2.4.0 macOS / 1.0 iOS (Build 6)] - 2026-05-19

### Stability
- **Relay lifecycle hardening**: Added 90-second watchdog timer for boot failures with auto-offer of "Force Restart". Added 5-second forced timeout to `stopRelay()` with state reset to idle.
- **Persist interaction state**: `likedEventIds` and `zappedEventIds` now persist to disk with throttled writes, surviving cold launches.
- **Error recovery UX**: Replaced status-message-only boot failures with actionable error sheets (Retry / Force Restart / Clear Locks) with clear explanations for port conflicts and database lock issues.

### UI/UX Polish
- **Empty state improvements**: Feed now distinguishes "Relay Starting..." from "No Following Feed" with contextual status messages and a Refresh Feed action.
- **Connection status refinement**: Expanded feed status dot to three states: green (live), orange (reconnecting), red (disconnected). Status dot is tappable to view relay details.
- **Navigation consistency**: Unified navigation with NavigationStack approach and gesture-based swipe-to-dismiss from ProfileView with drag threshold feedback.

### Code Quality
- **Split WebSocketClient.swift**: Extracted `NostrService.swift` (~1,250 lines) and `MediaCacheService.swift` (~530 lines) from the monolithic WebSocketClient, reducing it to ~460 lines.

## [2.4.0 macOS / 1.0 iOS (Build 5)] - 2026-03-11

### Added
- **Blossom Mirroring (macOS)**: Enabled the Blossom media mirroring service on macOS, allowing users to download their remote media to the local relay for offline access and faster loading.
- **Interactive Liked/Zapped States**: The Note Detail view now features persistent visual indicators for likes (red heart) and zaps (orange bolt) with spring animations when triggered.
- **Auto-Mirroring on Startup**: Introduced a setting to automatically mirror your own media from external servers whenever the relay starts, ensuring your local library is always in sync.
- **Media Swipe Gestures**: Implemented intuitive vertical swipe-to-dismiss gestures for full-screen media in both the Blossom media viewer and the note attachment viewer.
- **Gesture-Based Dimming**: Added interactive background opacity and media scaling that reacts to drag progress, providing visual depth and feedback during dismissal.
- **Unified Media Interaction**: Refactored viewer components to support consistent swiping and scaling for both image and video content.

### Changed
- **Real-time Replies**: The reply section in the Note Detail view now updates in real-time as new events arrive, providing a more dynamic and responsive threading experience.
- **Improved Feed Navigation**: Added an automatic "Scroll to Top" feature when switching filters or refreshing the feed.
- **Project Modernization**: Updated Xcode project settings to follow current Apple recommendations (LastUpgradeCheck 17.0).

### Fixed
- **Blossom Service Warnings**: Resolved compiler warnings regarding unused variables in the Blossom download pipeline.

## [2.4.0 macOS / 1.0 iOS (Build 3)] - 2026-03-03

### Fixed
- **Blossom Uploads Broken**: Removed redundant custom Blossom HTTP handlers that were intercepting requests before they reached the native `khatru/blossom` server. This was blocking standard BUD-02 `PUT /upload` requests and causing 400 errors from web clients.
- **Blossom CORS Errors**: Added proper CORS headers (`Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`) and `OPTIONS` preflight handling to resolve `XMLHttpRequest cannot load` errors when uploading media from web-based Nostr clients.
- **Blossom Downloads with File Extensions**: The khatru/blossom server now handles all GET requests natively, including URLs with file extensions (e.g., `/<sha256>.jpg`), fixing `Invalid SHA256 hash` errors when viewing media.
- **macOS Local Upload Protocol Mismatch**: Fixed `BlossomService` to use `http://` instead of `https://` for local Blossom uploads on macOS, since the Mac relay runs plain HTTP (Cloudflare handles TLS externally). The hardcoded `https://localhost:3355` URL was failing silently after TLS was disabled for the macOS C-shared relay.
- **Standardized Upload Endpoint**: Updated `BlossomService` to use the BUD-02 standard `PUT /upload` endpoint for all uploads (local and remote), replacing the non-standard `PUT /<sha256>` path.

### Added
- **Tailscale / LAN Network Support**: Expanded local network detection to recognize Tailscale IPs (`100.x.x.x`, `.ts.net`), as well as standard LAN ranges (`192.168.x`, `10.x`, `172.x`). This prevents the app from incorrectly forcing HTTPS or altering upload paths when connecting to your own relay over a local network.

## [2.4.0 macOS / 1.0 iOS (Build 2)] - 2026-03-03

### Added
- **iOS Support (1.0)**: Initial launch of the Haven iOS app with a unified codebase. Features include cross-platform support with shared services, views, and Go library builds.
- **C-Shared Library Architecture**: Embedded the Go relay as a static library (`libhaven.a`) directly linked into the Swift app. This improves reliability, simplifies process management (no more helper process), and enables universal (arm64 + x86_64) binary builds.
- **NIP-49 Private Key Encryption**: Added support for encrypting the Nostr private key (nsec) using a password (ncryptsec), with secure password storage in the system Keychain for automatic signing.
- **Nostr Zaps & NWC**: Full implementation of Nostr Zaps and Nostr Wallet Connect (NWC). Users can now send and receive lightning tips directly within the app, with real-time balance tracking.
- **Smart Inbox Broadcasting**: When replying or reacting to a note, Haven now automatically fetches the author's preferred relay configuration (Kind 10002) and broadcasts your response to their specific inbox relays, ensuring better delivery in a fragmented Nostr relay landscape.
- **Mac Relay Sync (iOS)**: A new background sync feature for iOS that allows the app to fetch missed notes from an always-on Mac Haven relay.
    - Added **Pull-to-Refresh** to the Feed, Viewer, and Note Detail views to manually trigger a Mac relay sync and catch missed notes.
    - Improved sync filter logic to include Kind 7 (Reactions), Kind 3 (Contacts), and direct mentions from strangers to ensure a complete timeline.


- **Direct Messaging (NIP-04)**: Initial support for NIP-04 private messaging and notifications.
- **UGC Reporting & Blocking**: Added user-generated content (UGC) reporting and blocking functionality to comply with App Store safety standards.
- **Web of Trust persistence**: WoT results are now cached locally, significantly speeding up relay startup by avoiding a full re-fetch of the Nostr network on every boot.
- **MIME Detection Pipeline**: Implemented a comprehensive MIME type detection system for the media viewer, improving support for extensionless Blossom items and note media.
- **Settings & Advanced Configuration**: 
    - Introduced dedicated tabs for **Access Control** (Whitelist/Blacklist), **Wallet** (Zaps), and **Logs**.
    - Added a **Factory Reset** option to clear all data and reset configurations.
    - Improved relay boot logs on the Dashboard for better transparency during startup (e.g., "Analyzing network connections"), and filtered out raw internal metadata like `total_keys=` to keep logs clean.
- **Privacy & Compliance**: Added a comprehensive Privacy Manifest (`PrivacyInfo.xcprivacy`) and export compliance declarations required for App Store distribution.


### Changed
- **Feed UI/UX Overhaul**:
    - Added **Pull-to-refresh** support for the timeline.
    - Added a floating **New Posts** indicator to jump to the top of the feed.
    - Improved threading UI with clear visual indicators for replies and parent notes.
    - Enhanced the Feed and Note details UI with **native grouped background colors**, replacing washed-out backgrounds and improving text contrast.
    - Increased feed limit to 500 events and optimized loading performance.
    - Unified media viewer with a source filter (Blossom vs. Cache).

- **Relay Process Management**: Replaced `os.Exit` with graceful connection handling during the import flow to prevent app crashes.
- **Bundle ID**: Updated macOS and iOS App Store bundle identifier to align with cross-platform identity (`com.havenapp.relay`).
- **Entitlements Tightened**: Hardened runtime and removed JIT and unsigned memory requirements for better security and App Store compliance.

### Fixed
- **App Transport Security**: Fixed HTTP media playback issues on macOS and iOS by properly configuring `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription`.
- **Feed Rendering**: Resolved issues with thread deduplication, pull-to-refresh animation logic, and missing non-owner posts.
- **Compose View Layout**: Fixed layout and styling of the Reply sheet on macOS to prevent content cropping.
- **Backup Verification**: Added checksum and integrity checks for `.zip` and `.jsonl` backups before restoration.
- **Sandbox Permissions**: Resolved "Operation not permitted" errors during database and media imports by using temporary directory staging.


## [2.3.0] - 2026-02-20

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, open **Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway**.

> [!NOTE]
> **Coming Soon**: The next release will move to a **C-shared relay architecture**, compiling the Go relay directly into the Swift app as a single process. This is required for App Store and TestFlight distribution. See [C_SHARED_RELAY.md](docs/C_SHARED_RELAY.md) for details on what's changing.

### Added
- **Audio Playback**: The media viewer now supports playing `.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, and `.ogg` audio files with a dedicated player UI featuring play/pause, seek controls, and a progress scrubber. Audio files are also detected via magic bytes (ID3, RIFF/WAVE) for extensionless Blossom items.
- **Blossom File Extensions**: Media exports now use a trust-but-verify system — querying the relay for MIME metadata and cross-checking against file magic bytes — to apply accurate file extensions. Supports virtually all file types via UTType, with magic-byte verification for JPEG, PNG, GIF, WebP, AVIF, HEIC, TIFF, BMP, MP4, MOV, WebM, MP3, WAV, FLAC, OGG, ZIP, APK, GZIP, and PDF. Additional fallback coverage for AAC, Opus, M4A, MKV, SVG, TAR, DOCX, XLSX, PPTX, and JAR.
- **Blossom Import**: Importing media automatically strips extensions to ensure compatibility with the relay.
- **Dashboard Quick Actions**: Added "Export JSONL" and "Export Blossom" buttons directly to the Dashboard for easier backups.
- **Import Button Rename**: Clarified the "Import" button on the Dashboard to "Import Notes".
- **Media Tab Filter**: Added a source filter to the Media Tab, allowing users to toggle between "Blossom" (local/uploaded) and "Cache" (captured from notes) media.
- **Dynamic Search Bar**: The search bar is now context-aware, appearing only in "Notes" mode and being replaced by the source filter in "Media" mode.
- **Whitelist & Blacklist Management**: Moved to a dedicated "Access Control" tab in Settings, with multi-npub support and corresponding config fields written to JSON.
- **DB Engine Selection**: Added a database engine step to the Setup Wizard allowing users to choose between storage backends.
- **JSONL Export/Import**: Replaced the old cloud-only backup UI with local JSONL export and import via native save/open panels in Settings.
- **Automatic Lock Recovery**: When a database lock is detected, the app now force-kills stale processes, clears lock files, and restarts the relay automatically.
- **"Fix & Restart" Button**: Replaced the multi-step "open Terminal and run pkill" error overlay with a one-click Retry button that handles cleanup automatically.
- **Backup Restore from Setup Wizard**: Users can now restore from a `.zip` or `.jsonl` backup during initial setup, with port conflict detection and retry support.
- **Setup Wizard: Blossom Media Restore**: Added Blossom media import as a dedicated setup wizard step (previously only available in Settings).
- **Floating Menu Bar Arrow**: After setup completion, a floating animated purple arrow with a glow effect points at the menu bar relay icon with a "Your relay lives here" label, helping new users locate the app.
- **C-Shared Relay Architecture** *(in development on `feat/c-shared-relay`)*: The Go relay is now compiled as a static C library (`libhaven.a`) and linked directly into the Swift app — making HAVEN a single-process application. This eliminates child process management, orphaned processes, and PID tracking. Required for App Store / TestFlight distribution.
- **Upstream Sync**: Pulled latest upstream changes from `bitvora/haven` into `haven-go/`.
- **Project Documentation**: Added `docs/RELEASE_PROCESS.md` (step-by-step release guide), `docs/C_SHARED_RELAY.md` (architecture overview of the c-shared approach), and `docs/upstream-sync.md` (subtree sync instructions).

### Changed
- **Dashboard Relays Hidden by Default**: The relay list on the Dashboard is now collapsed by default to reduce visual clutter, toggled via the existing eye icon.
- **Dashboard Layout**: Improved vertical spacing so the Dashboard fills the window height.
- **Setup Wizard: Split Import/Restore into Dedicated Steps**: The single "Import Your Data" step has been split into three independent, skippable steps: "Import from Relays" (pull notes from external relays), "Restore Notes" (restore JSONL backup), and "Restore Media" (restore Blossom media).
- **Setup Window Sizing**: Fixed inconsistent window sizes between the initial launch popup and the menu bar "Start Setup" flow. Both now open at 600x700.
- **Application Performance**: Optimized UI responsiveness by caching regex patterns and moving heavy computations off the main thread.
- **Relay Error Handling**: Improved relay error popups by removing the ineffective "Fix and Restart" option and providing clearer instructions for the "pkill" command.
- **Setup Wizard Overhaul**: Rewrote the setup flow with ScrollView support, a new identity step with inline whitelist editing, and a dedicated database engine step.
- **Backup Settings Simplified**: Removed AWS and GCP backup providers; streamlined to S3-compatible only for cloud backups.
- **Welcome Window**: The pre-setup menu bar view now shows a simple "Start Setup" prompt that opens the wizard in a dedicated window, rather than embedding the full wizard inline.
- **Process Startup**: `state = .booting` is now set immediately and synchronously before any async work, preventing a race where two relay processes could launch simultaneously.
- **Shutdown Reliability**: `stopRelay()` now waits up to 5 seconds for the process to exit and escalates to SIGKILL if SIGTERM is ignored. App termination wait increased from 0.2s to 1.0s.

### Fixed
- **Priority Inversions**: Resolved runtime priority inversion warnings in image loading by making `ImageDownsampler.downsample` async with `.utility` priority, and updating call sites in `AnimatedImage.swift` and `ViewerView.swift`.
- **Sandbox Permissions**: Resolved "Operation not permitted" errors during backup and import by using temporary directories for zip/unzip operations.
- **Improved Backup Reliability**: Replaced direct file archiving with a safer two-step process to avoid permission issues.
- **Dashboard UI**: Fixed an issue where export status messages could persist indefinitely.
- **Database Lock Boot Loop**: Fixed a critical race condition where two haven processes could start simultaneously, causing them to fight over database locks and loop forever.
- **Inactivity Timer**: Replaced broken `Timer`-based implementation (which couldn't mutate SwiftUI struct state) with a proper `Task.sleep` approach that correctly resets to the dashboard tab.
- **Import Log Parsing**: Added a byte-level log buffer (`processBufferedOutput`) to handle multibyte characters and incomplete lines during note import, preventing hangs.
- **Duplicate readabilityHandler**: Removed a dead first pipe handler in `importNotes` that was immediately overwritten by a second one.
- **Settings Save Leak**: Added `onDisappear` cancellation of the debounced save task in SettingsView.

### Known Issues
- This release is not eligible for App Store distribution. The following changes are in progress on `feat/c-shared-relay`:
  - Embed the Go relay as a C-shared library (replacing the separate helper process) for full App Sandbox compliance
  - Remove disallowed entitlements (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`)
  - Add required Privacy Manifest (`PrivacyInfo.xcprivacy`)
  - Replace blanket `NSAllowsArbitraryLoads` with `NSAllowsLocalNetworking`
  - Add `ITSAppUsesNonExemptEncryption` declaration

## [2.2.1] - 2026-02-07

### Added
- **Web of Trust Improvements**: Added configurable WoT Depth and Minimum Followers settings in the Advanced tab.
- **WoT Refresh Control**: Introduced a configurable refresh interval for the Web of Trust network (1h, 12h, 24h, 7d).

### Changed
- **macOS Sandbox Optimization**: Implemented a 256KB userspace buffer workaround to bypass the macOS Sandbox `sendfile` bug, improving media streaming stability.
- **Relay URL Generation**: Centralized and improved relay URL generation to handle local and remote connections more reliably.

### Fixed
- **WoT Pruning**: Improved WoT pruning logic and logging for better transparency.
- **Thread Safety**: Refined thread-safety in the relay backend and standardized internal benchmarks.

## [2.2.0] - 2026-01-30

### Added
- **Video Playback Overhaul**: Rewritten interaction with local media to handle extensionless files (Blossom) using a smart symlinking strategy.
- **Media Viewer Sorting**: Media items are now strictly sorted by Nostr event timestamp (newest first).
- **Backend Refactor**: Extracted Web of Trust functionality into a dedicated package (`haven-go/wot`) with lockless refresh support.
- **Handshake Support**: Added `User-Agent: Haven/1.0` header to resolve connection issues with specific relays.

### Fixed
- **Thumbnail Generation**: Resolved decoding errors for extensionless video files by adding settled-state detection.
- **Layout Stability**: Fixed layout constraint warnings and UI "crunch" errors in the video player controls.

## [2.1.1] - 2026-01-25

### Changed
- **Repo Restructuring**: Separated logic into `haven-go/` (backend) and `HavenApp/` (Swift UI) for better transparency and easier auditing.
- **Verifiable Builds**: Standardized documentation for building the Go backend from source.

### Fixed
- **Sandbox Media streaming**: Initial implementation of the userspace buffer fix for the macOS Sandbox bug.

## [2.1.0] - 2026-01-22

### Added
- **Pop-out Viewer Window**: Ability to pop out the viewer into an independent, multi-tasking friendly window.
- **Automated Maintenance**: Intelligent detection and automatic resolution of database locks during startup.
- **Welcome Window**: A new guided experience for new users on first launch.

### Changed
- **Swift 6 Readiness**: Addressed strict concurrency violations and compiled with `SWIFT_STRICT_CONCURRENCY=complete`.
- **Media Layout**: Overhauled media scaling in the grid and full-screen viewer to prevent distortion.

### Fixed
- **SSL/TLS Handshake**: Resolved issues where local media would fail to load due to certificate/handshake errors.
- **Image Crashes**: Fixed crashes related to downsampling high-resolution images.

## [2.0.0] - 2026-01-20

### Added
- **Media Caching System**: Improved media loading performance and reduced redundant network fetches.
- **Real-time Statistics**: Added a dashboard to monitor relay performance and event counts.
- **Hardened Runtime**: Enabled macOS Hardened Runtime and configured proper entitlements for increased security.

### Fixed
- **CPU Optimization**: Significant reduction in CPU usage during relay startup and synchronization.
- **Import Reliability**: Improved reliability of data import and pre-import cleanup processes.

## [1.2.0] - 2026-01-19

### Added
- **Initial Native Release**: First native macOS desktop application for the Haven protocol.
- **Universal Binary**: Support for both Apple Silicon and Intel Macs.
- **Setup Wizard**: Guided flow for initial relay configuration.
- **Integrated Blossom**: Built-in Blossom media server for hosting images and videos.
- **Cloud Backups**: Integrated support for S3, AWS, and GCP backups.
