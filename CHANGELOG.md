# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
