# Haven App v2.4.0 (macOS) / v1.0 (iOS) Release Notes

This major update introduces the **initial launch of Haven for iOS**, a unified C-archive architecture, NIP-49 private key encryption, and full support for Nostr Zaps and Wallet Connect.

> [!IMPORTANT]
> **macOS Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## Key Features & Improvements

*   **iOS Support (1.0)**: Haven is now available on iOS! A unified codebase means the same robust relay technology and features are now available in your pocket.
*   **C-Shared Library Architecture**: The Go relay is now linked directly into the Swift binary as a static library. This eliminates external process management and ensures a more stable, unified application.
*   **NIP-49 Private Key Encryption**: Secure your Nostr identity with password-based encryption (ncryptsec). Your password is saved in the system Keychain for a seamless, secure signing experience.
*   **Nostr Zaps & NWC**: Support for Nostr Wallet Connect (NWC) lets you tip and be tipped directly from within Haven using Zaps.
*   **Mac Relay Sync (iOS Exclusive)**: Since mobile relays don't run 24/7, you can now connect your iOS Haven app to your always-on Mac Haven relay to sync missed notes automatically.
*   **Feed Overhaul**: Added pull-to-refresh, a "New Posts" indicator, and a context-aware media filter.
*   **Web of Trust Persistence**: WoT results are now cached locally, dramatically reducing startup time on subsequent launches.
*   **UGC Reporting & Safety**: Full support for reporting and blocking users to ensure a safe community environment.

## Bug Fixes

*   **App Transport Security**: Fixed media playback and local networking permissions issues on both platforms.
*   **Relay Stability**: Removed legacy helper processes and improved connection handling to prevent crashes.
*   **Feed Threading**: Fixed logic for displaying parent/child note relationships and improved deduplication.
*   **MIME Detection**: Improved media type detection for Blossom and Nostr media attachments.
*   **Sandbox & Permissions**: Optimized the data import and export pipeline to fully comply with modern macOS sandbox requirements.

Thank you for being part of the Haven community!
