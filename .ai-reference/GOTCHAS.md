# Known Issues, Gotchas, and Pitfalls

## macOS App Sandbox

### sendfile Truncation Bug
- **Problem**: Go's `http.ServeContent` uses the `sendfile()` syscall, which is restricted inside App Sandbox. Blob responses get truncated at 512 bytes or return empty.
- **Fix**: `haven-go/load_blob_darwin.go` wraps file handles in `safeReader` that implements `io.WriterTo` using a 256KB userspace buffer via `io.CopyBuffer()`.
- **Rule**: Never use `http.ServeFile()` or `http.ServeContent()` directly for blob serving on macOS. Always go through the `loadBlob` function.

### File Access Scope
- All file operations must stay within the Application Support directory (`relayDataDir`).
- `RelayProcessManager.startRelay()` sets the working directory to `relayDataDir` before calling `StartRelayC()`.
- Go code uses relative paths (e.g., `db/private/`, `blossom/`) which resolve relative to this working directory.

### LMDB mmap Limits
- App Sandbox limits virtual memory mapping.
- macOS default: 1 GB map size (safe).
- iOS default: 256 MB (strict memory limits).
- Configurable via `LMDB_MAPSIZE` env var.
- If relay won't start with LMDB errors, check map size.

## Database Lock Files

- BadgerDB and LMDB create `LOCK` files in their `db/` directories.
- If the relay crashes or is killed without calling `StopRelayC()`, LOCK files persist.
- **Symptom**: relay fails to start on next boot with lock-related errors.
- **Fix**: `RelayProcessManager.stopRelay()` automatically cleans LOCK files. If stuck, manually delete `db/*/LOCK` files in `relayDataDir`.
- The code at `RelayProcessManager.swift` scans for and removes these during startup.

## Duplicate HTTP Mux Registration Panic

- Go's `http.DefaultServeMux` panics if you register the same URL pattern twice.
- Haven creates a **fresh** `http.ServeMux` in each `StartRelayC()` call (line 119 of `cshared.go`).
- The 4 `khatru.Relay` instances are also re-created in `initRelays()` (line 160 of `init.go`).
- **Rule**: Never register routes on `http.DefaultServeMux`. Always use the per-cycle mux.

## Config Migration Crashes

- Adding a new `HavenConfig` field **without** a default value will crash when decoding old `config.json` files.
- **Rule**: Always use `decodeIfPresent` with `?? defaults.field` in `init(from:)`.
- **Rule**: Always provide a default in the struct declaration.
- **Rule**: Always add the new field to the `CodingKeys` enum.
- See `Models/HavenConfig.swift:131-206` for the full pattern.

## iOS-Specific Issues

### TLS Required for Local Connections
- iOS App Transport Security blocks plain HTTP to localhost.
- **Solution**: Self-signed TLS cert generated in `tls.go`, enabled by `HAVEN_ENABLE_TLS=1`.
- Swift must trust the self-signed cert via `LocalhostTrustDelegate` (in `WebSocketClient.swift`).
- `HavenConfig.nostrURL` returns `wss://` on iOS vs `ws://` on macOS.
- `HavenConfig.webURL` returns `https://` on iOS vs `http://` on macOS.

### BadgerDB vs LMDB on iOS
- LMDB map size must be small (256 MB) to avoid OOM.
- BadgerDB value log limited to 64 MiB (`init.go:80`).
- Swift defaults `dbEngine` to `"badger"` in `HavenConfig`.

### WoT Depth
- Level 3 WoT fetch can exhaust iOS memory.
- Go auto-reduces to depth 2 on iOS: `if runtime.GOOS == "ios" { defaultWotDepth = 2 }` (`config.go:81`).

## Build Issues

### Go Not Found in Xcode
- Xcode uses a minimal PATH that doesn't include Go.
- `build_haven.sh` adds `/opt/homebrew/bin`, `/usr/local/go/bin`, `$HOME/go/bin` to PATH.
- If Go still not found, add its install path to `build_haven.sh`.

### Linker Version Warnings
- Set `MACOSX_DEPLOYMENT_TARGET` in the build script to match the Xcode target.
- `CGO_LDFLAGS` includes `-mmacosx-version-min` to suppress warnings.

### Stale libhaven.a
- Xcode may cache the old library and not rebuild Go code.
- **Fix**: Clean Build Folder (Cmd+Shift+K) if Go changes aren't reflected.

## WebSocket Issues

### Reconnection After Relay Restart
- After relay restart, existing WebSocket connections may not reconnect immediately.
- `WebSocketClient` has exponential backoff (max 10 attempts, max 30s delay).
- Monitor logs for reconnection attempts.

### Skipping Local Relay During Boot
- During relay boot, the Swift app skips connecting to the local relay to avoid timeout hangs.
- Once `RelayProcessManager.state == .running`, connections are established.

## Process Conflicts

- If a previous Haven process is still running (crashed without cleanup), the new instance can't bind to the port.
- `RelayProcessManager` shows `showProcessKillAlert` with instructions to run `pkill -9 haven`.
- This is a manual step the user must perform.

## npub Sanitization

- User-pasted npubs may contain invisible Unicode characters (non-breaking spaces, zero-width joiners).
- `ConfigService` strips non-alphanumeric characters: `.filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }`
- This sanitization runs on init, save, and recovery.

## Upstream Sync Conflicts

- `init.go` is the primary conflict point during `git subtree pull`.
- **Always preserve**: lazy initialization pattern, error returns from `initDBs()`/`initRelays()`, `CloseDBs()`.
- **Always preserve** in `main.go`: `isCShared()` early return.
- New upstream files usually merge cleanly.
- See `docs/upstream-sync.md` for the full workflow.

## afero Filesystem

- Go code uses `afero.Fs` (virtual filesystem) instead of `os.Open()` directly.
- This is for App Sandbox compatibility — `fs.Open()` resolves paths correctly in sandboxed environments.
- Assigned in `StartRelayC()`: `fs = afero.NewOsFs()`.
- Blossom blob operations (`fs.Create()`, `fs.Remove()`) use this filesystem.
