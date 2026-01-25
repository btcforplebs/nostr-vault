# Haven App v2.1.1 Release Notes

This update addresses critical issues with media loading and accessibility.

> [!IMPORTANT]
> **Installation Note**: Haven is currently unsigned code. macOS will likely block the application from opening by default. To bypass this, simply **Right-Click (or Control-Click)** the app and select **Open**. You may need to do this twice.

## Bug Fixes & Optimizations

*   **Optimized macOS Sandbox Media Streaming**: Implemented a high-performance **256KB userspace buffer** workaround to bypass the macOS Sandbox `sendfile` bug. Benchmarks confirm this fix is not only more stable but also significantly more robust under high concurrent load compared to the native system call.
*   **Relay URL Generation**: Centralized and improved relay URL generation to handle local and remote connections more reliably.
*   **Benchmark Suite & Stability**: Standardized the internal benchmark suite for performance verification and refined thread-safety in the relay backend.

Thank you for using Haven!

