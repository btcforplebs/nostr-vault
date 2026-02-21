# Haven App v2.3.0 Release Notes

This major update introduces the **Whitelist Tab**, improved process management, robust media handling, and critical reliability fixes for the database and relay.

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## Key Features & Improvements

*   **Whitelist Tab**: A dedicated view to follow only your most trusted contacts. Supports multiple npubs for a curated feed experience.
*   **Blossom Media Extensions**: Exported media now automatically includes the correct file extension (e.g., .jpg, .png) detected from the file content, making backups much easier to browse.
*   **Smart Import**: The import process automatically handles extension stripping, ensuring seamless compatibility with the relay.
*   **PID Persistence & Automatic Recovery**: Haven now tracks process IDs to automatically clean up orphaned relays on startup, preventing "database is locked" errors.
*   **One-Click "Fix & Restart"**: Replaces manual troubleshooting with a simple button to resolve relay connection or lock issues automatically.
*   **Dashboard Quick Actions**: Added "Export JSONL" and "Export Blossom" buttons directly to the Dashboard for faster access to backups.
*   **Performance Optimizations**: Batched metadata fetching and local caching significantly speed up note and media loading.

## Bug Fixes

*   **Sandbox Permissions**: Resolved "Operation not permitted" errors during backup and import by utilizing temporary directories for safe file operations.
*   **Backup Reliability**: Improved the reliability of creating and restoring zip archives.
*   **Database Lock Boot Loop**: Fixed a critical race condition that caused the app to fight over database locks on launch.
*   **Note Import Robustness**: Improved handling of large data imports to prevent hangs and crashes.
*   **Swift 6 Isolation**: Fixed MainActor violations and concurrency issues to ensure stability on modern macOS.
*   **Viewer Layout**: Resolved text overflow and layout "crunch" errors in the viewer and video player.

## What's Next: App Store & TestFlight

We are actively working toward **App Store distribution**. The `v2.3.0-tf` build (available on the `feat/c-shared-relay` branch) replaces the sub-process architecture with a **C-shared library** approach — compiling the Go relay directly into the Swift app as a single process. This is required for Apple's App Store and TestFlight.

If you'd like to help test the TestFlight version, check out the `v2.3.0-tf` tag or watch for the TestFlight link once approved.

For technical details, see [`docs/C_SHARED_RELAY.md`](../docs/C_SHARED_RELAY.md).

Thank you for using Haven!
