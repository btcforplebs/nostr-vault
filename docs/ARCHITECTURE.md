# Architecture: HAVEN for Mac

HAVEN for Mac is designed to provide the world-class sovereignty of the `bitvora/haven` Nostr relay with the ease of use of a native macOS application.

## High-Level Overiew

The project consists of two primary layers:

1.  **Go Core (99% of Codebase)**: The identical, battle-tested Go code from `bitvora/haven`. This handles all Nostr protocol logic, database management (BadgerDB/LMDB), Blossom media serving, and cloud backups.
2.  **Swift UI Layer**: A lightweight macOS native wrapper built with SwiftUI. It provides a user-friendly interface for configuration, status monitoring (logs/stats), and managing the relay lifecycle.

## How it Works

- **Embedded Relay**: When you launch HAVEN for Mac, the Swift application starts the Go backend as a sub-process.
- **Inter-Process Communication**: The Swift UI monitors the Go process via standard output (logs) and communicates configuration changes through environment variables and configuration files.
- **Native Experience**: By using Swift, Haven integrates perfectly with macOS, supporting native menus, notifications, and the macOS Sandbox.

## Verifiability

One of our core principles is **Don't Trust, Verify**. 

Even though we provide a pre-packaged `.app` and `.zip`, any user can:
1.  Build the Go binary independently from the root of this repository.
2.  Inspect the Swift code in `HavenApp/` to see exactly how it launches the binary.
3.  Verify that no modifications have been made to the core logic.

See [BUILD_MAC.md](./BUILD_MAC.md) for instructions on how to build and verify the project yourself.
