# Architecture: HAVEN for Mac

HAVEN for Mac brings the sovereignty of the [bitvora/haven](https://github.com/bitvora/haven) Nostr relay to a native macOS application.

## High-Level Overview

The project consists of two layers:

1.  **Go Core**: The battle-tested Go code from `bitvora/haven`. This handles all Nostr protocol logic, database management (BadgerDB), Blossom media serving, Web of Trust, and cloud backups.
2.  **Swift UI Layer**: A native macOS wrapper built with SwiftUI. It provides a user-friendly interface for configuration, status monitoring (logs/stats), media management, and relay lifecycle control.

## How it Works

- **C-Shared Library**: The Go code is compiled into a static library (`libhaven.a`) that links directly into the Swift app. HAVEN runs as a single process — no child process management, no orphaned processes.
- **Direct Function Calls**: The Swift app controls the relay via C-exported Go functions (`StartRelayC`, `StopRelayC`, `BackupDatabaseC`, etc.) rather than IPC over pipes.
- **Configuration**: Environment variables are passed to Go via `SetHavenEnvC()` before starting the relay. The `.env` file is managed by the Swift layer.
- **Native Experience**: SwiftUI integrates with macOS menus, notifications, and the App Sandbox.

## Go Source Management

The Go code lives under `haven-go/` via `git subtree` (remote: `upstream`). See [upstream-sync.md](./upstream-sync.md) for details on syncing with upstream.

### Downstream Modifications

The following files are added or modified on top of upstream:

| File | Purpose |
|------|---------|
| `cshared.go` | C-exported entry points (`StartRelayC`, `StopRelayC`, etc.). Build-tagged `//go:build cshared`. |
| `cshared_stub.go` | `isCShared() bool { return false }` stub for standalone builds. |
| `load_blob_darwin.go` | macOS-specific blob loading with `safeReader` to work around Go sendfile sandbox truncation. |
| `init.go` | Lazy initialization of DB/relay globals to support stop/start cycles. Error returns instead of panics. |
| `main.go` | Early-return when `isCShared()`. Deferred config loading. |

## Verifiability

One of our core principles is **Don't Trust, Verify**.

Even though we provide a pre-packaged `.app`, any user can:
1.  Build the Go library and Swift app from source.
2.  Inspect the Swift code in `HavenApp/` to see exactly how it calls into the Go library.
3.  Verify that no modifications have been made to the core relay logic.

See [VERIFY_BUILD.md](./VERIFY_BUILD.md) for instructions on how to build and verify the project yourself.
