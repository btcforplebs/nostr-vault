# Verifying HAVEN for Mac

HAVEN for Mac is fully open-source. You can build it from source to verify that the distributed app matches the code in this repository.

## What You're Verifying

The Go relay code from [bitvora/haven](https://github.com/bitvora/haven) is compiled into a static library (`libhaven.a`) and linked into the Swift app at build time. There is no separate binary — the Go code runs in-process.

This means verification is done by building the entire app from source and comparing it to the distributed version.

## Build from Source

### Prerequisites

- [Go 1.24+](https://go.dev/dl/)
- macOS 14.0+
- Xcode 15+

### Steps

1.  Clone the repository:
    ```bash
    git clone https://github.com/btcforplebs/haven-mac.git
    cd haven-mac
    ```

2.  Check out the release tag you want to verify:
    ```bash
    git checkout v2.3.0
    ```

3.  Open the project and build:
    ```bash
    open HavenApp/HavenApp.xcodeproj
    ```
    Then **Product > Archive** in Xcode, or **Cmd+B** for a debug build.

## Verify the Go Source

The Go code under `haven-go/` is managed via `git subtree` from upstream. You can verify it has not been tampered with:

1.  Compare `haven-go/` against the upstream repo:
    ```bash
    git log --oneline haven-go/
    ```
    Upstream commits will appear on a separate branch line. Any downstream modifications (for macOS sandbox compatibility) are committed separately and can be individually inspected.

2.  Review the downstream modifications. These are documented in [ARCHITECTURE.md](./ARCHITECTURE.md) and are limited to:
    - `cshared.go` / `cshared_stub.go` — C-export bridge (additive, no upstream conflict)
    - `load_blob_darwin.go` — macOS sandbox workaround (additive)
    - `init.go` — Lazy initialization for stop/start cycles
    - `main.go` — Early-return when running as a library

## Inspect the Swift Layer

The Swift code in `HavenApp/` is the UI wrapper. You can inspect it to verify:
- How environment variables and configuration are passed to Go (`SetHavenEnvC`)
- How the relay is started and stopped (`StartRelayC`, `StopRelayC`)
- That no modifications are made to the core relay logic

---

**HAVEN for Mac** - Powered by [bitvora/haven](https://github.com/bitvora/haven)
