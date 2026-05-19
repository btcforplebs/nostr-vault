# Go Relay Backend Reference

## Source Location

- **Path**: `haven-go/` (git subtree from `bitvora/haven`, remote: `upstream`)
- **Package**: `main` (all files in root)
- **Sub-packages**: `pkg/wot/`, `internal/cloud/`
- **Go version**: 1.24.1 (see `haven-go/go.mod`)

## Build Tags

- `cshared` tag: enables `cshared.go` (C-exported functions), disables `main()` in `main.go`
- **Build command** (library): `go build -tags cshared -buildmode=c-archive -ldflags="-s -w" -o libhaven.a`
- **Build command** (standalone): `go build -v -ldflags="-s -w" -o haven`

## File-by-File Reference

### `cshared.go` — C Bridge (build tag: `cshared`)

All `//export` functions callable from Swift. Contains:
- Global state: `csharedCtx`, `csharedCancel`, `globalServer`
- `isCShared() bool { return true }`
- `SetHavenEnvC(key, value)` — sets env var via `os.Setenv()`
- `StartRelayC(importMode bool)` — reloads config, creates pool, inits DBs/relays, starts HTTP server
  - If `importMode`: runs `runImport()` then returns
  - Otherwise: starts relay + background services (WoT, subscriptions, backups, blastr)
  - Creates **fresh** `http.ServeMux` each call (avoids duplicate pattern panic)
  - TLS only when `HAVEN_ENABLE_TLS=1`
- `StopRelayC()` — cancels context, shuts down server, closes DBs
- `BackupDatabaseC(outputPath) int` — inits DBs, exports to ZIP, returns 0/1
- `RestoreDatabaseC(inputPath) int` — inits DBs, imports from ZIP, returns 0/1
- `BackupToCloudC() int` — export + upload to S3
- `RestoreFromCloudC() int` — download from S3 + import
- `ZipDirectoryC(dirPath, zipPath) int` / `UnzipDirectoryC(zipPath, destPath) int`
- `SignEventC(jsonStr, sk) *C.char` — unmarshal event, sign with key, return signed JSON
- `GenerateKeyPairC() *C.char` — returns `"sk:pk"` format
- `GetPublicKeyC(sk) *C.char` — derive pubkey from secret key
- `EncryptNIP04C` / `DecryptNIP04C` — NIP-04 shared secret encryption
- Empty `main()` — required for c-archive build mode

### `cshared_stub.go` — Standalone Stub

```go
func isCShared() bool { return false }
```

### `init.go` — Core Initialization

**Global variables** (line 24-56):
```go
var pool   *nostr.SimplePool
var config Config
var fs     afero.Fs
var privateRelay, chatRelay, outboxRelay, inboxRelay *khatru.Relay
var privateDB, chatDB, outboxDB, inboxDB, blossomDB  DBBackend
var blossomServer *blossom.BlossomServer
var dbs map[string]DBBackend
```

**Key functions**:
- `newDBBackend(path string) DBBackend` — factory: returns badger or lmdb backend based on `config.DBEngine`
- `newLMDBBackend(path string)` — platform-aware map sizes (iOS: 256MB, macOS: 1GB)
- `initDBs() error` — calls `GranularInitDBs(["private","chat","outbox","inbox","blossom"])`
- `GranularInitDBs(names []string) error` — creates DBs, assigns to globals
- `CloseDBs()` — closes all open databases
- `initRelays(ctx context.Context) error` — **the most important function**:
  1. Creates 4 fresh `khatru.NewRelay()` instances
  2. Calls `initDBs()`
  3. Calls `initRelayLimits()`
  4. Configures each relay: info metadata, policy chains, store/query handlers, HTTP routes
  5. Sets up Blossom server on outboxRelay
  6. Runs `migrateBlossomMetadata()`
- `dynamicRelayHandler(w, r)` — routes by `r.URL.Path` to correct relay
- `getLogLevelFromConfig() slog.Level` — maps string to slog level

### `config.go` — Configuration

**Config struct** (line 26-73): all fields with JSON tags. Key fields:
- `OwnerNpub`, `OwnerPubKey` (derived)
- `DBEngine` (default: "lmdb"), `LmdbMapSize`
- `BlossomPath` (default: "blossom")
- `RelayURL`, `RelayPort` (default: 3355), `RelayBindAddress` (default: "0.0.0.0")
- Per-relay: `{Private,Chat,Outbox,Inbox}Relay{Name,Npub,Description,Icon}`
- Import: `ImportSeedRelays []string`, `ImportStartDate`, timeouts
- WoT: `WotDepth` (default: 3, 2 on mobile), `WotMinimumFollowers`, `WotCachePath`, `WotCacheTTLMinutes`
- Backup: `BackupProvider`, `BackupIntervalHours`, `S3Config`
- Access: `WhitelistedPubKeys map[string]struct{}`, `BlacklistedPubKeys map[string]struct{}`
- Blastr: `BlastrRelays []string`, `BlastrTimeoutSeconds`

**`loadConfig() Config`** (line 77): reads `.env` via godotenv, builds Config from env vars. Owner pubkey is always added to whitelist.

**Helper functions**: `getEnv`, `getEnvString`, `getEnvInt`, `getEnvInt64`, `getEnvBool`, `getEnvDuration`, `nPubToPubkey`, `getRelayListFromFile`, `getNpubsFromFile`, `getS3Config`

### `policies.go` — Access Control

Policy functions return `(reject bool, reason string)`:
- `MustBeWhitelistedToQuery` — checks `khatru.GetAuthed(ctx)` against whitelist
- `MustBeWhitelistedToPost` — checks event pubkey OR authed user against whitelist
- `MustBeInWotToQuery` / `MustBeInWotToPost` — checks against WoT instance
- `MustNotBeBlacklistedToPost` — checks both event author and authed user
- `EventMustBeChatRelated` — checks `event.Kind` against `allowedChatKinds` map
- `OnlyGiftWrappedDMs` — rejects `KindEncryptedDirectMessage` (kind 4), allows all others
- `MustTagWhitelistedPubKey` — requires at least one "p" tag matching a whitelisted pubkey

**`allowedChatKinds`** (line 80-106): NIP-29 simple group kinds, channel kinds, gift wrap (1059)

### `import.go` — Event Import

- `runImport(ctx)` — orchestrates import: owner notes → tagged notes
- `ensureImportRelays()` — validates connectivity to seed relays
- `importOwnerNotes()` — fetches events by whitelisted pubkeys, chunked by 240 hours
- `importTaggedNotes()` — fetches events tagging whitelisted pubkeys
- `subscribeInboxAndChat(ctx)` — real-time subscription to seed relays (waits for WoT ready)

### `blastr.go` — Event Broadcasting

- `blast(ctx, event)` — broadcasts to all `config.BlastrRelays` via goroutines
- `publishWithRetry(ctx, relayURL, event, timeout, maxRetries)` — exponential backoff (1s, 2s, 4s)

### `backup.go` — Backup/Restore

- `exportToZip(ctx, zipFileName)` / `importFromZip(ctx, zipFileName)`
- `uploadBackupToCloud(ctx, provider, filename)` / `downloadBackupFromCloud(ctx, provider, filename)`
- `startPeriodicCloudBackups(ctx)` — ticker at `config.BackupIntervalHours`

### `tls.go` — Self-Signed Certificates

- `getOrCreateSelfSignedCert(dataDir) (certPath, keyPath, error)`
- Generates RSA-2048, X.509 cert valid 10 years for localhost/127.0.0.1/::1
- Only used when `HAVEN_ENABLE_TLS=1` (iOS builds)

### `limits.go` — Rate Limiting

- `initRelayLimits()` — reads per-relay rate limit env vars
- Per-relay structs: `{Private,Chat,Outbox,Inbox}RelayLimits`
- Controls: event IP rate, connection rate, allow empty/complex filters

### `load_blob_darwin.go` — macOS Blob Loading

- `loadBlob` returns an `io.ReadSeeker` wrapped in `safeReader`
- `safeReader` implements `io.WriterTo` using 256KB buffer + `io.CopyBuffer`
- **Why**: Go's `sendfile()` syscall truncates at 512 bytes inside App Sandbox

### `load_blob_default.go` — Non-Darwin Blob Loading

- `loadBlob` returns `fs.Open()` directly (no wrapper needed)

### `pkg/wot/` — Web of Trust

**`wot.go`**: interfaces (`Model`, `Refresher`, `Initializer`), singleton management
- `Initialize(ctx, model)` — calls `model.Init(ctx)`, marks ready
- `WaitReady(ctx)` — blocks until WoT is initialized
- `PeriodicRefresh(ctx, interval)` — periodic refresh loop
- `GetInstance() Model` — returns current WoT model

**`simple_in_memory.go`**: `SimpleInMemory` implementation
- `Has(ctx, pubkey) bool` — checks if pubkey is in WoT
- `Init(ctx)` — fetches follow lists from seed relays, builds graph
- `Refresh(ctx)` — rebuilds graph
- `LoadFromCache()` / `SaveCache()` — persists to `wot_cache.json`
- Batches: 1000 pubkeys per relay request, 100ms sleep between batches (iOS responsiveness)

### `internal/cloud/s3.go` — S3 Backup Provider

- `NewGenericS3Provider(endpoint, accessKey, secret, region)` — creates MinIO client
- `Upload(ctx, bucket, objectName, reader, size, contentType)`
- `Download(ctx, bucket, objectName) io.ReadCloser`

## Key Dependencies (go.mod)

| Package | Purpose |
|---------|---------|
| `github.com/fiatjaf/khatru` v0.19.1 | Nostr relay framework |
| `github.com/fiatjaf/khatru/blossom` | Blossom media server |
| `github.com/fiatjaf/eventstore/badger` | BadgerDB event storage |
| `github.com/fiatjaf/eventstore/lmdb` | LMDB event storage |
| `github.com/nbd-wtf/go-nostr` v0.52.3 | Nostr protocol library |
| `github.com/dgraph-io/badger/v4` v4.9.1 | BadgerDB engine |
| `github.com/spf13/afero` v1.15.0 | Virtual filesystem (sandbox compat) |
| `github.com/joho/godotenv` v1.5.1 | .env file loading |
| `github.com/minio/minio-go/v7` v7.0.98 | S3 client |
| `github.com/mailru/easyjson` | Fast JSON marshaling for events |
