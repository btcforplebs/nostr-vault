# Haven App v2.0.0 Release Notes

We are thrilled to announce the release of Haven App 2.0.0! This major update brings significant new features, performance improvements, and critical bug fixes to enhance your Nostr experience on macOS.

## New Features

*   **Pop-out Viewer Window**: You can now pop out the viewer into its own independent window, perfect for multi-tasking and keeping your feed visible while you work.
*   **Welcome Window**: A brand new welcome experience guides new users on first launch, making it easier than ever to get started with Haven.
*   **Automated Database Maintenance**: The app now intelligently detects and automatically resolves database locks, ensuring your relay starts smoothly every time without manual intervention.
*   **Media Caching**: A new caching system improves media loading performance and reliability.

## Improvements

*   **Performance Optimization**: Significant reduction in CPU usage, particularly resolving issues where the app could lock up during relay startup.
*   **Media Layout**: Completely overhauled media handling in the grid and full-screen viewer. Images and videos now scale correctly without distortion or cropping issues.
*   **Connectivity**: Improved WebSocket connection logic with smarter retry mechanisms to ensure stable connections to your relay.
*   **Security**: Enabled Hardened Runtime and configured proper entitlements for better integration with macOS security features.

## Bug Fixes

*   **SSL/TLS Handshake**: Fixed issues where local media would fail to load due to SSL errors.
*   **Image Crashes**: Resolved crashes related to image thumbnail downsampling.
*   **UI Glitches**: Fixed deprecated code warnings and various layout glitches in the viewer and dashboard.
*   **Import/Export**: Improved reliability of data import and pre-import cleanup processes.

Thank you for using Haven!
