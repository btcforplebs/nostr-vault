# System Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Swift UI Layer (HavenApp/)                │
│  ┌──────────────┐  ┌─────────────┐  ┌───────────────────┐  │
│  │ ConfigService │  │ NostrService│  │RelayProcessManager│  │
│  │ (config.json) │  │ (WebSocket) │  │ (Go lifecycle)    │  │
│  └──────┬───────┘  └──────┬──────┘  └────────┬──────────┘  │
│         │                 │                   │              │
│    save config      fetch events     SetHavenEnvC()         │
│    load config      sign events      StartRelayC()          │
│    generate .env    publish events   StopRelayC()           │
│         │                 │          BackupDatabaseC()       │
│         │                 │          SignEventC()            │
└─────────┼─────────────────┼──────────┼──────────────────────┘
          │                 │          │
          ▼                 │          ▼
   ┌──────────┐            │   ┌──────────────────────────────┐
   │.env file │            │   │   Go Relay (libhaven.a)      │
   │config.json│           │   │   via C-archive bridge       │
   └──────────┘            │   │                              │
                           │   │  ┌──────────────────────┐   │
                           │   │  │  HTTP Server (:3355)  │   │
                           ├───┼──│  /private → privateR  │   │
                           │   │  │  /chat    → chatR     │   │
                           │   │  │  /inbox   → inboxR    │   │
                           │   │  │  /        → outboxR   │   │
                           │   │  │  PUT /upload → Blossom│   │
                           │   │  │  GET /<sha> → Blossom │   │
                           │   │  └──────────────────────┘   │
                           │   │                              │
                           │   │  ┌──────────────────────┐   │
                           │   │  │  5 Databases          │   │
                           │   │  │  db/private           │   │
                           │   │  │  db/chat              │   │
                           │   │  │  db/outbox            │   │
                           │   │  │  db/inbox             │   │
                           │   │  │  db/blossom           │   │
                           │   │  └──────────────────────┘   │
                           │   │                              │
                           │   │  Background Services:        │
                           │   │  - WoT init & refresh        │
                           │   │  - Inbox/chat subscriptions  │
                           │   │  - Cloud backups             │
                           │   │  - Blastr broadcasting       │
                           │   └──────────────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ Nostr Network │
                    │ (seed relays, │
                    │  blastr, WoT) │
                    └──────────────┘
```

## Two-Layer Design

### Go Core (`haven-go/`)
Compiled as `libhaven.a` using `-buildmode=c-archive -tags cshared`. Runs as a **thread inside the Swift app process** (not a child process). Contains:
- 4 khatru relay instances (Private, Chat, Inbox, Outbox)
- Blossom media server (mounted on outboxRelay)
- BadgerDB or LMDB event storage (5 databases)
- Web of Trust engine with disk cache
- Event import, broadcasting, and backup systems

### Swift UI Layer (`HavenApp/`)
macOS menu bar app (MenuBarExtra). Manages Go lifecycle via direct C function calls. Contains:
- 17+ services (singletons, @MainActor, ObservableObject)
- 20+ SwiftUI views
- Config persistence (config.json + .env generation)
- WebSocket client for Nostr subscriptions
- Media upload/caching, Lightning payments, key management

## C Bridge Interface

All exported functions live in `haven-go/cshared.go`. Swift calls them directly via the bridging header.

### Relay Lifecycle
```c
void SetHavenEnvC(char* key, char* value);  // Set env var before start
void StartRelayC(_Bool importMode);          // Boot relay or run import
void StopRelayC(void);                       // Graceful shutdown
```

### Database Operations
```c
GoInt BackupDatabaseC(char* outputPath);     // Export all DBs to ZIP → 0=success, 1=fail
GoInt RestoreDatabaseC(char* inputPath);     // Import from ZIP
GoInt BackupToCloudC(void);                  // Upload to S3
GoInt RestoreFromCloudC(void);               // Download from S3
GoInt ZipDirectoryC(char* dirPath, char* zipPath);
GoInt UnzipDirectoryC(char* zipPath, char* destPath);
```

### Cryptography
```c
char* SignEventC(char* jsonStr, char* sk);   // Sign Nostr event → signed JSON (or nil)
char* GenerateKeyPairC(void);                // Generate keypair → "sk:pk"
char* GetPublicKeyC(char* sk);               // Derive pubkey → hex (or nil)
char* EncryptNIP04C(char* plaintext, char* pubkey, char* privkey);
char* DecryptNIP04C(char* ciphertext, char* pubkey, char* privkey);
```

### Bridge Mechanics
- **Header**: `HavenApp/HavenApp/HavenApp-Bridging-Header.h` includes `../build/libhaven.h`
- **String params**: Swift passes C strings; Go converts with `C.GoString()`
- **Return strings**: Go returns `C.CString()` — caller responsible for freeing
- **Error pattern**: int returns use 0=success, 1=failure; string returns use nil for errors
- **Panic safety**: every exported function has `defer func() { if r := recover(); r != nil { ... } }()`

## Sub-Relay Architecture

Haven runs **4 distinct relays** on a single HTTP port, routed by URL path via `dynamicRelayHandler()` in `haven-go/init.go:458`.

| Relay | Path | Read Access | Write Access | Special Behavior |
|-------|------|-------------|--------------|------------------|
| **Private** | `/private` | Whitelisted + auth | Whitelisted only | Personal vault |
| **Chat** | `/chat` | WoT + auth | WoT + not blacklisted | Chat kinds only (NIP-29 groups, channels, gift wrap) |
| **Outbox** | `/` (root) | Public | Whitelisted only | Auto-blasts events to external relays; Blossom server mounted here |
| **Inbox** | `/inbox` | Public | WoT + not blacklisted | Gift-wrapped DMs only (kind 1059); must tag a whitelisted pubkey |

### Routing Logic (`dynamicRelayHandler`)
```go
switch r.URL.Path {
case "/private": relay = privateRelay
case "/chat":    relay = chatRelay
case "/inbox":   relay = inboxRelay
default:         relay = outboxRelay  // "/" and all Blossom paths
}
```

## Database Architecture

**Interface** (`haven-go/init.go:58`):
```go
type DBBackend interface {
    Init() error
    Close()
    CountEvents(ctx context.Context, filter nostr.Filter) (int64, error)
    DeleteEvent(ctx context.Context, evt *nostr.Event) error
    QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error)
    SaveEvent(ctx context.Context, evt *nostr.Event) error
    ReplaceEvent(ctx context.Context, evt *nostr.Event) error
    Serial() []byte
}
```

**Engines**: `"badger"` (default in Swift) or `"lmdb"` (default in Go standalone)
- BadgerDB: vlog limited to 64 MiB for iOS mmap safety
- LMDB: map size defaults — iOS: 256 MB, macOS: 1 GB

**Paths** (relative to working dir, which is `relayDataDir`):
`db/private/`, `db/chat/`, `db/outbox/`, `db/inbox/`, `db/blossom/`

## Blossom Media Server

Mounted on `outboxRelay` in `init.go:363`:
```go
blossomServer = blossom.New(outboxRelay, "https://"+config.RelayURL)
blossomServer.Store = blossom.EventStoreBlobIndexWrapper{Store: blossomDB, ServiceURL: ...}
```

- **Upload**: `PUT /upload` — only whitelisted pubkeys (checked via `RejectUpload`)
- **Download**: `GET /<sha256>` — served via `loadBlob` (platform-specific)
- **Delete**: `DELETE /<sha256>` — removes file from `config.BlossomPath`
- **Blobs stored** as files named by SHA256 hash in `config.BlossomPath` directory

## Web of Trust (WoT)

- **Implementation**: `haven-go/pkg/wot/simple_in_memory.go`
- **Cache**: `wot_cache.json` in relay data dir (TTL: 1440 min / 24h default)
- **Startup**: loads from cache first (instant), then refreshes async in background
- **Depth**: 3 on macOS (default), 2 on iOS (memory constraint)
- **Used by**: Chat relay (query + post), Inbox relay (post)
- **Refresh**: periodic via `wot.PeriodicRefresh()` goroutine

## Networking

| Protocol | Used For | Implementation |
|----------|----------|----------------|
| WebSocket (ws/wss) | Nostr relay protocol | khatru framework (Go), WebSocketClient (Swift) |
| HTTP/HTTPS | Blossom media, relay info pages | Go net/http server |
| Self-signed TLS | iOS localhost (ATS requirement) | `tls.go`, enabled by `HAVEN_ENABLE_TLS=1` |
| LNURL/NWC | Lightning payments | Swift NWCService, LNURLService, ZapService |

## Security Model

- **App Sandbox**: enabled on macOS (`HavenApp.entitlements`)
- **Private keys**: stored encrypted via NIP-49 (`ownerNcryptsec`); plaintext `ownerNsec` only for migration
- **TLS**: self-signed for iOS localhost; macOS uses plain HTTP (Cloudflare handles TLS in production)
- **Access control**: whitelist + WoT + blacklist checked per-relay via policy chains
- **Blossom uploads**: restricted to whitelisted pubkeys via `RejectUpload`
