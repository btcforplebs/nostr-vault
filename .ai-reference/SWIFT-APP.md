# Swift App Layer Reference

## Source Location

- **Path**: `HavenApp/HavenApp/`
- **Subdirectories**: `App/`, `Models/`, `Services/`, `Views/`, `Views/Components/`
- **Deployment targets**: macOS 14.0+, iOS 17.0+
- **Frameworks**: SwiftUI, Combine, CryptoKit, CommonCrypto, AVFoundation, ServiceManagement

## App Entry Point & Lifecycle

### `App/HavenApp.swift`

```swift
@main struct HavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate  // macOS only
    @StateObject private var configService = ConfigService.shared
    @StateObject private var relayManager = RelayProcessManager.shared
    @StateObject private var nostrService = NostrService.shared
    @StateObject private var statsService = StatsService.shared
}
```

**Scenes (macOS)**:
1. `MenuBarExtra("Haven", systemImage: "server.rack")` — main menu bar UI
2. `Window("Haven Setup", id: "setup")` — setup wizard (hidden initially)
3. `Settings` — settings window
4. `Window("Haven", id: "viewer-window")` — popped-out viewer

**Scene (iOS)**: `WindowGroup` with `MenuBarContent`

All scenes inject the 4 shared services via `.environmentObject()` and apply `.preferredColorScheme(.dark)`.

### `App/AppDelegate.swift`

- `NSApplicationDelegate` on macOS
- Forces dark color scheme
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` (menu bar app stays alive)

### Startup Flow

1. `HavenApp.init()` creates shared service singletons
2. `MenuBarContent.onAppear` checks `config.hasCompletedSetup`
   - If false: shows welcome screen with "Start Setup" button → opens setup window
   - If true: shows `MenuBarView`, auto-starts relay via `relayManager.startRelay(config:)`

## Service Architecture

All services follow the same pattern:
```swift
@MainActor class ServiceName: ObservableObject {
    static let shared = ServiceName()
    @Published var someState: Type
}
```

### ConfigService (`Services/ConfigService.swift`, 453 lines)

**Singleton**: `ConfigService.shared`

**Storage paths**:
- Config: `~/Library/Application Support/Haven/config.json`
- Relay data: `~/Library/Application Support/Haven/haven_database/`

**Key properties**:
- `config: HavenConfig` (published)
- `relayDataDir: URL`

**Key methods**:
- `save()` — encodes config to JSON, writes relay lists, updates launch-at-login
- `reload()` — reloads from disk
- `createRequiredFiles()` — creates .env + relay JSON files + blossom directory
- `resetApp()` — deletes all data and config (factory reset)
- `recoverFromEnv()` — reconstructs config from existing .env file (migration recovery)
- `whitelistedHexPubkeys: Set<String>` — computed, decodes npubs to hex

### RelayProcessManager (`Services/RelayProcessManager.swift`, 1600+ lines)

**Singleton**: `RelayProcessManager.shared`

**State machine**: `idle → booting → running → stopping → idle` (also: `importing`)

**Key properties**:
- `state: RelayState` (published)
- `bootProgress: Double`, `importProgress: Double`
- `isLocked: Bool`, `showProcessKillAlert: Bool`
- `logEntries: [LogEntry]`
- `relayMemoryUsage: String`, `relayCPUUsage: String`

**Key methods**:
- `startRelay(config:)` — generates .env, creates dirs, clears lock files, calls `SetHavenEnvC` for all env vars, dispatches `StartRelayC(false)` on background thread
- `stopRelay()` — calls `StopRelayC()`, waits 1s for file lock release, cleans lock files
- `importNotes(config:)` — stops relay if running, runs `StartRelayC(true)` (import mode)
- `forceCleanAndRestart()` — force-stop + clean locks + restart
- `generateEnvDictionary(config:) -> [String: String]` — maps Swift config to env vars (line 913)
- `generateMinimalEnv(config:) -> String` — generates .env file content

**Log capture**: redirects file descriptors, parses Go slog output on background DispatchQueue. Extracts state from patterns like "connected successfully", "Imported X notes", "Initializing WoT", etc.

### NostrService + WebSocketClient + MediaCacheService (`Services/WebSocketClient.swift`, 2085 lines)

This single large file contains three classes: `WebSocketClient` (low-level WebSocket), `NostrService` (Nostr protocol operations, starts at line ~301), and `MediaCacheService` (media download/caching, starts at line ~1557). All are singletons.

**NostrService key capabilities**:
- `signEvent(kind:content:tags:password:)` — calls `SignEventC()` via Go bridge
- `postEvent(_ event:)` — posts to local relay + blastr relays + smart broadcast to author's inbox relays
- `fetchNotes(from:until:authors:)` — WebSocket REQ with filters
- `fetchMissingProfiles(for:)` — batched metadata fetch
- `fetchRelayList(for:)` — kind 10002 relay list fetch
- `fetchCount(from:)` — NIP-45 COUNT

**Connection management**: exponential backoff reconnect, 25s keepalive pings, `LocalhostTrustDelegate` for self-signed certs

**MediaCacheService** (in same file, line ~1557):
- Cache/blossom directory management
- Download queue (max 4 concurrent), thumbnail queue (max 2 concurrent)
- MIME type detection via magic bytes
- `fetchData(url:)`, `localFileURL(for:)`, `preparePlayableURL(for:)`, `generateThumbnail(for:)`

### FeedService (`Services/FeedService.swift`, ~720 lines)

- Event fetching from local relay
- Profile caching and lookup (persisted to `profiles.json`)
- Feed composition (notes, reposts, reactions)
- Media URL extraction from event content
- `followUser(_ pubkey:)` / `unfollowUser(_ pubkey:)` — modifies `followedPubkeys`, signs and publishes updated kind 3 contact list. Guards against publishing when contacts haven't loaded (`isLoadingContacts`, `count > 1`). Preserves original kind 3 content (relay hints).

### BlossomService (`Services/BlossomService.swift`, 560 lines)

- `uploadAndMirror(data:sha256:)` — upload to local Blossom, then mirror to external servers
- BUD-02 auth event signing (kind 24242)
- Concurrent uploads to configured `blossomMirrors`
- Returns external mirror URL only (not local 127.0.0.1)
- 3 retry attempts per mirror with exponential backoff

### NWCService (`Services/NWCService.swift`, 521 lines)

- Nostr Wallet Connect (NIP-47)
- Parses `nostr+walletconnect://` URI
- Creates temporary WebSocket to wallet relay
- `payInvoice(bolt11:) -> preimage`
- NIP-04 encrypted messages to wallet

### ZapService (`Services/ZapService.swift`, 85 lines)

Full zap flow:
1. Resolve Lightning Address via LNURLService
2. Build kind 9734 zap request
3. Sign via NostrService
4. Fetch Bolt11 invoice from LNURL callback
5. Pay via NWCService

### LNURLService (`Services/LNURLService.swift`, 128 lines)

- `resolveAddress(_ lud16:)` — resolves `user@domain` to LNURL Pay Response
- `fetchInvoice(callback:amountMsat:zapRequest:)` — gets Bolt11 invoice

### NIP49Service (`Services/NIP49Service.swift`, 310 lines)

- `encrypt(nsec:password:) -> String` — nsec → ncryptsec (PBKDF2 + AES-256-GCM)
- `decrypt(ncryptsec:password:) -> String` — ncryptsec → nsec
- 262,144 PBKDF2 iterations, random 16-byte salt, 24-byte nonce

### Other Services

| Service | File | Purpose |
|---------|------|---------|
| `NIP04Service` | `NIP04Service.swift` (57 lines) | NIP-04 DM encryption via Go bridge |
| `StatsService` | `StatsService.swift` (184 lines) | Event count queries per relay |
| `LogStore` | `LogStore.swift` (52 lines) | Thread-safe log buffer with 1s throttle |
| `MirrorService` | `MirrorService.swift` (155 lines) | Auto-mirror media from external servers |
| `MacRelaySyncService` | `MacRelaySyncService.swift` (417 lines) | iOS sync from Mac relay |
| `PushNotificationService` | `PushNotificationService.swift` (112 lines) | Push notifications |
| `NostrContentFormatter` | `NostrContentFormatter.swift` (119 lines) | Content parsing (npub/note mentions) |
| `Theming` | `Theming.swift` (24 lines) | Color constants (`.havenPurple`) |

## Models

### HavenConfig (`Models/HavenConfig.swift`)

Codable struct with ~50 fields. Key design:
- **All fields have defaults** — safe for migration
- `init(from:)` uses `decodeIfPresent` with `?? defaults.field` for every field
- Computed: `sanitizedRelayURL`, `isLocal`, `nostrURL` (ws/wss), `webURL` (http/https)
- Key management: `getDecryptedNsec(password:)`, `getDecryptedHexKey(password:)`, `setEncryptedNsec(nsec:password:)`
- Platform-aware: `nostrURL` uses `ws://` on macOS, `wss://` on iOS

### NostrEvent (`Models/NostrEvent.swift`)

```swift
struct NostrEvent: Codable, Identifiable {
    let id: String
    let pubkey: String
    let created_at: Int64
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String
    var parentEventId: String?
    var isReply: Bool
}
```

### Other Models

- `FeedProfile` — user profile (pubkey, name, displayName, pictureURL, nip05, lud16, about)
- `MediaItem` — media (url, type, dateAdded, pubkey, tags, mimeType)

## View Hierarchy

| View | File | Purpose |
|------|------|---------|
| `MenuBarView` | `Views/MenuBarView.swift` | Main menu bar UI: status, feed, metrics |
| `DashboardView` | `Views/DashboardView.swift` | Stats, connection info, relay status |
| `FeedView` | `Views/FeedView.swift` | Note feed display |
| `ComposeView` | `Views/ComposeView.swift` | New note composition with media upload |
| `NoteDetailView` | `Views/NoteDetailView.swift` | Single note with replies |
| `ProfileView` | `Views/ProfileView.swift` | User profile sheet with bio, NIP-05, follow/unfollow, zap, swipe-to-dismiss. Streams author's notes from relays (own WebSocket clients). Notes open in NoteDetailView via NavigationStack sheet. |
| `SettingsView` | `Views/SettingsView.swift` | All configuration tabs |
| `SetupWizardView` | `Views/SetupWizardView.swift` | First-run setup (multi-step) |
| `LogsView` | `Views/LogsView.swift` | Relay log viewer |
| `FeedMediaViewer` | `Views/FeedMediaViewer.swift` | Media gallery with swipe |
| `ViewerView` | `Views/ViewerView.swift` | General viewer |
| `RelayListEditor` | `Views/RelayListEditor.swift` | Edit relay URL lists |
| `CachedAsyncImage` | `Views/CachedAsyncImage.swift` | Image caching |
| `VideoPlayerView` | `Views/VideoPlayerView.swift` | Video playback |
| `AudioPlayerView` | `Views/AudioPlayerView.swift` | Audio playback |

## Platform Differences

| Aspect | macOS | iOS |
|--------|-------|-----|
| Window type | `MenuBarExtra` (menu bar app) | `WindowGroup` |
| Local relay protocol | `ws://` / `http://` | `wss://` / `https://` (TLS) |
| `HAVEN_ENABLE_TLS` | `"0"` | `"1"` |
| WoT depth default | 3 | 2 (memory) |
| DB engine default | `"badger"` (Swift default) | `"badger"` |
| Pasteboard | `NSPasteboard` | `UIPasteboard` |
| App activation | `NSApp.activate()` | N/A |
| Platform conditionals | `#if os(macOS)` | `#if os(iOS)` |
