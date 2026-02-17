# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Whitelist Tab**: Added a dedicated "Whitelisted" tab to the Viewer to display notes and media from trusted npubs (excluding own notes).
- **Multi-Npub Support**: Expanded configuration and UI to support multiple whitelisted npubs.
- **PID Persistence**: Haven process PIDs are now saved to disk, allowing the app to find and kill orphaned processes from previous sessions on startup.
- **Automatic Lock Recovery**: When a database lock is detected, the app now automatically SIGKILLs stale processes, clears Badger lock files, and restarts the relay without user intervention.
- **"Fix & Restart" Button**: Replaced the manual "open Terminal and run pkill" error overlay with a one-click "Fix & Restart" button that handles cleanup automatically.
- **Improved "All" Tab**: Refined the global feed to prioritize user notes and mentions, creating a more relevant default view.
- **Metadata Caching**: Implemented batched metadata fetching with local caching to improve Viewer loading times.

### Fixed
- **Database Lock Boot Loop**: Fixed a critical race condition where two haven processes could start simultaneously (due to `state = .booting` being set inside an async Task instead of immediately), causing them to fight over Badger locks and loop forever.
- **Stop Relay Reliability**: `stopRelay()` now waits up to 5 seconds for the process to exit and escalates to SIGKILL if SIGTERM is ignored, preventing orphaned processes that hold database locks.
- **Swift 6 Sendable Fixes**: Fixed MainActor isolation violations in backup/restore completion handlers in SettingsView and SetupWizardView.
- **Viewer Text Overflow**: Fixed "Whitelisted" and "Media" button labels wrapping to multiple lines in the Viewer tab bar.
- **Import Robustness**: Fixed a critical hang during note import by implementing a byte-level log buffer to handle multibyte characters and split lines.
- **Git History Restoration**: Used `git subtree` to cleanly merge upstream history into `haven-go/`, ensuring proper attribution and easier future updates.

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
