# Haven App v2.3.0 Release Notes

This major update introduces the **Whitelist Tab**, improved process management, and critical reliability fixes for the database and relay.

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## Key Features & Improvements

*   **Whitelist Tab**: A dedicated view to follow only your most trusted contacts. Supports multiple npubs for a curated feed experience.
*   **PID Persistence & Automatic Recovery**: Haven now tracks process IDs to automatically clean up orphaned relays on startup, preventing "database is locked" errors.
*   **One-Click "Fix & Restart"**: Replaces manual troubleshooting with a simple button to resolve relay connection or lock issues automatically.
*   **Performance Optimizations**: Batched metadata fetching and local caching significantly speed up note and media loading.

## Bug Fixes

*   **Database Lock Boot Loop**: Fixed a critical race condition that caused the app to fight over database locks on launch.
*   **Note Import Robustness**: Improved handling of large data imports to prevent hangs and crashes.
*   **Swift 6 Isolation**: Fixed MainActor violations and concurrency issues to ensure stability on modern macOS.
*   **Viewer Layout**: Resolved text overflow and layout "crunch" errors in the viewer and video player.

Thank you for using Haven!
