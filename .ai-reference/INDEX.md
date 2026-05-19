# Haven AI Agent Reference

## How to Use This Folder

Read this file first. It tells you which document to open for any topic. Each document is self-contained with file paths, function signatures, and code patterns. You should not need to hunt through the codebase to get started.

**All file paths are relative to the repo root** (`/`).

## Project Identity

Haven is a **macOS/iOS app** that embeds a **Go Nostr relay** as a C-shared static library (`libhaven.a`). The app runs as a menu bar item on macOS. There is no test suite — testing is manual.

- **Swift app**: `HavenApp/` — SwiftUI, macOS 14+, iOS 17+
- **Go relay**: `haven-go/` — git subtree from `bitvora/haven` (remote: `upstream`)
- **Bridge**: Go compiled as `c-archive` with `//go:build cshared` tag, linked via `HavenApp-Bridging-Header.h`

## Quick Navigation

| I need to...                                      | Read this                |
|---------------------------------------------------|--------------------------|
| Understand the overall system design              | ARCHITECTURE.md          |
| Work on Go relay code (DB, policies, WoT, import) | GO-RELAY.md              |
| Work on Swift views or services                   | SWIFT-APP.md             |
| Understand config flow (Swift -> env -> Go)       | CONFIG-AND-DATA-FLOW.md  |
| Build, run, archive, or release the app           | BUILD-SYSTEM.md          |
| Add a new feature (step-by-step recipes)          | COMMON-TASKS.md          |
| Understand coding style and patterns              | CONVENTIONS.md           |
| Avoid known bugs and pitfalls                     | GOTCHAS.md               |

## Key File Quick-Reference

### Go Backend (`haven-go/`)

| File | Purpose |
|------|---------|
| `haven-go/cshared.go` | C-exported functions: `StartRelayC`, `StopRelayC`, `SignEventC`, etc. (build tag: `cshared`) |
| `haven-go/cshared_stub.go` | `isCShared() bool { return false }` for standalone builds |
| `haven-go/init.go` | Global vars, `DBBackend` interface, `initDBs()`, `initRelays()`, `dynamicRelayHandler()`, `CloseDBs()` |
| `haven-go/config.go` | `Config` struct, `loadConfig()` from env vars, helper functions |
| `haven-go/policies.go` | Access control: `MustBeWhitelistedToPost`, `MustBeInWotToPost`, `allowedChatKinds`, etc. |
| `haven-go/import.go` | Event import from seed relays: `runImport()`, `ensureImportRelays()` |
| `haven-go/blastr.go` | Event broadcasting: `blast()`, `publishWithRetry()` |
| `haven-go/tls.go` | Self-signed cert generation: `getOrCreateSelfSignedCert()` |
| `haven-go/main.go` | Standalone CLI entry point (defers when `isCShared()`) |
| `haven-go/limits.go` | Rate limiter config per relay |
| `haven-go/backup.go` | Backup/restore: `exportToZip()`, `importFromZip()`, cloud operations |
| `haven-go/load_blob_darwin.go` | macOS sandbox-safe blob loading with `safeReader` |
| `haven-go/pkg/wot/` | Web of Trust: `SimpleInMemory`, `Has()`, `Refresh()`, cache persistence |
| `haven-go/internal/cloud/s3.go` | S3 backup provider |

### Swift App (`HavenApp/HavenApp/`)

| File | Purpose |
|------|---------|
| `App/HavenApp.swift` | `@main` entry point, scene definitions, environment injection |
| `App/AppDelegate.swift` | `NSApplicationDelegate`, dark mode enforcement |
| `App/build_haven.sh` | macOS Go library build script (Xcode build phase) |
| `App/build_haven_ios.sh` | iOS Go library build script |
| `App/HavenApp.entitlements` | App Sandbox, network client/server, camera |
| `HavenApp-Bridging-Header.h` | C bridging header (includes `build/libhaven.h`) |
| `Models/HavenConfig.swift` | Config struct (Codable), URL helpers, key decryption |
| `Models/NostrEvent.swift` | Nostr event struct, kind descriptions, reply detection |
| `Services/RelayProcessManager.swift` | Go process lifecycle, log parsing, env generation (1600+ lines) |
| `Services/WebSocketClient.swift` | WebSocketClient + NostrService + MediaCacheService (2085 lines) |
| `Services/ConfigService.swift` | Config persistence, .env generation, relay list management |
| `Services/FeedService.swift` | Event fetching, profile caching |
| `Services/BlossomService.swift` | Media upload/mirror, BUD-02 auth |
| `Services/NWCService.swift` | Nostr Wallet Connect, Lightning payments |
| `Services/NIP49Service.swift` | NIP-49 key encryption/decryption |
| `Services/ZapService.swift` | Zap (Lightning tip) flow |
| `Services/LNURLService.swift` | LNURL-pay resolution |
| `Services/StatsService.swift` | Relay statistics queries |
| `Services/LogStore.swift` | Relay log buffering |
| `Views/MenuBarView.swift` | Main menu bar UI |
| `Views/SettingsView.swift` | All configuration tabs |
| `Views/SetupWizardView.swift` | First-run setup flow |
| `Views/FeedView.swift` | Note feed display |
| `Views/ComposeView.swift` | New note composition |

### Project Root

| File | Purpose |
|------|---------|
| `docs/ARCHITECTURE.md` | Brief architecture overview (original project docs) |
| `docs/DIVERGENCE.md` | Differences from upstream bitvora/haven |
| `docs/upstream-sync.md` | Git subtree workflow |
| `docs/C_SHARED_RELAY.md` | C-shared library design rationale |
| `CHANGELOG.md` | Version history (builds 2-5) |
