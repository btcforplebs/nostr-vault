# Haven App v2.1.0 Release Notes

We are thrilled to announce the release of Haven App 2.1.0! This major update brings significant new features, performance improvements, and critical bug fixes to enhance your Nostr experience on macOS.

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.
**Runtime Note** if the relay fails to start initially, run **pkill -9 haven** in the terminal.

## New Features

*   **Pop-out Viewer Window**: You can now pop out the viewer into its own independent window, perfect for multi-tasking and keeping your feed visible while you work.
*   **Welcome Window**: A brand new welcome experience guides new users on first launch, making it easier than ever to get started with Haven.
*   **Automated Database Maintenance**: The app now intelligently detects and automatically resolves database locks, ensuring your relay starts smoothly every time without manual intervention.
*   **Media Caching**: A new caching system improves media loading performance and reliability.
*   **Relay Statistics**: Added real-time statistics tracking to monitor relay performance and event counts.

## Improvements

*   **Performance Optimization**: Significant reduction in CPU usage, particularly resolving issues where the app could lock up during relay startup.
*   **Media Layout**: Completely overhauled media handling in the grid and full-screen viewer. Images and videos now scale correctly without distortion or cropping issues.
*   **Connectivity**: Improved WebSocket connection logic with smarter retry mechanisms to ensure stable connections to your relay.
*   **Security**: Enabled Hardened Runtime and configured proper entitlements for better integration with macOS security features.
*   **Swift 6 Readiness**: Addressed strict concurrency violations across the codebase, ensuring future-proof code and thread-safety compliance.
*   **Stability**: Codebase is now compiled with `SWIFT_STRICT_CONCURRENCY=complete`, resolving potential race conditions in relay management, websocket connectivity, and media caching.

## Bug Fixes

*   **SSL/TLS Handshake**: Fixed issues where local media would fail to load due to SSL errors.
*   **Image Crashes**: Resolved crashes related to image thumbnail downsampling.
*   **UI Glitches**: Fixed deprecated code warnings and various layout glitches in the viewer and dashboard.
*   **Import/Export**: Improved reliability of data import and pre-import cleanup processes.
*   **Scrolling Stability**: Fixed a crash that could occur when scrolling through a large list of text notes.

Thank you for using Haven!
