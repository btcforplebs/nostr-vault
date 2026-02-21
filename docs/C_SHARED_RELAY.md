# C-Shared Relay: Go as a Static Library

## Overview

The `feat/c-shared-relay` branch replaces the sub-process architecture with a **C-shared library** approach. Instead of launching the Go relay as a separate binary, the Go code is compiled into a static library (`libhaven.a`) that links directly into the Swift app. This makes HAVEN a single-process application — required for App Store distribution and more robust overall.

## Why C-Shared?

- **App Store compliance**: Apple does not allow bundled executables that act as separate server processes.
- **Single process**: No child process management, no orphaned processes, no PID tracking.
- **Cleaner lifecycle**: `StartRelayC()` / `StopRelayC()` are direct function calls, not IPC over stdout.
- **No sendfile bugs**: The macOS sandbox `sendfile` truncation issue (Go #70000) is handled in-process.

## What Changed in Go

The Go changes on top of upstream `bitvora/haven` are minimal:

### New files (additive, no upstream conflicts)

| File | Lines | Purpose |
|------|-------|---------|
| `cshared.go` | ~230 | C-exported entry points: `StartRelayC`, `StopRelayC`, `BackupDatabaseC`, `RestoreDatabaseC`, `BackupToCloudC`, `RestoreFromCloudC`, `SetHavenEnvC`. Build-tagged `//go:build cshared`. |
| `cshared_stub.go` | 7 | `isCShared() bool { return false }` for the standalone binary build. |
| `load_blob_darwin.go` | ~35 | macOS-specific blob loading with `safeReader` wrapper to avoid sendfile truncation in the sandbox. |

### Modified files

| File | What changed |
|------|-------------|
| `init.go` | **Lazy initialization**: Global relay/DB vars changed from `var x = newX()` to `var x *Type`, created inside `initRelays()`/`initDBs()`. This allows stop/start cycles without panicking on duplicate mux registrations. `initDBs()` and `initRelays()` now return `error` instead of calling `panic()`. Added `CloseDBs()` to cleanly shut down all databases. |
| `main.go` | Deferred `config = loadConfig()` (was global init). Early-returns if `isCShared()`. Added `defer CloseDBs()`. Changed `initRelays()` call to handle the new error return. |

### Files that should NOT be tracked

`libhaven.a`, `libhaven.h`, and `haven.dylib` are build artifacts. They should be in `.gitignore`.

## Upstream Sync Impact

When pulling upstream changes via `git subtree pull --prefix=haven-go upstream master`:

- **`cshared.go`** and **`cshared_stub.go`**: Will never conflict (upstream doesn't have them).
- **`init.go`**: The only file likely to conflict. Upstream changes to relay/DB initialization will need to be reconciled with the lazy-init pattern.
- **`main.go`**: Low conflict risk — the changes are small and near the top of `main()`.

The `init.go` changes (error returns instead of panics, lazy DB creation) are arguably improvements that could be proposed upstream to `bitvora/haven`.

## Build Differences

### Standalone binary (master, original)

```bash
go build -v -ldflags="-s -w" -o haven
```

Produces a standalone executable. The Swift app launches it as a child process.

### C-shared static library (c-shared-relay)

```bash
go build -tags cshared -buildmode=c-archive -ldflags="-s -w" -o libhaven.a
```

Produces `libhaven.a` + `libhaven.h`. The Swift app links against the static library via a bridging header. The Xcode build phase (`build_haven.sh`) handles this automatically, including universal (arm64 + x86_64) builds for archive.

## Swift-Side Differences

| Aspect | Standalone (master) | C-Shared |
|--------|-------------------|----------|
| Relay start | `Process()` launch | `StartRelayC(0)` function call |
| Relay stop | `SIGTERM` + `SIGKILL` | `StopRelayC()` function call |
| Log capture | Pipe from stdout/stderr | Redirect file descriptors in-process |
| Config passing | `.env` file + env vars | `SetHavenEnvC()` + `.env` file |
| DB lock handling | Kill process + delete LOCK files | `CloseDBs()` + delete LOCK files |
| Build script | Builds standalone binary | Builds `libhaven.a` via `c-archive` |

## Migration Path

Once the c-shared branch is stable:

1. Tag master as `v2.x-standalone-final`
2. Merge `feat/c-shared-relay` into master
3. Continue development on master only
4. Delete the feature branch
