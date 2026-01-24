# Haven App v2.1.1 Release Notes

This update addresses critical issues with media loading and accessibility.

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## Bug Fixes

*   **macOS Sandbox Media Serve**: Resolved a critical issue where media files (images/videos) would fail to load or be truncated at 512 bytes due to macOS Sandbox restrictions on the `sendfile` system call.
*   **Relay URL Generation**: Centralized and improved relay URL generation to handle local and remote connections more reliably.
*   **Stability**: Further refined thread-safety and concurrency handling in the relay backend.

Thank you for using Haven!
