# Configuration and Data Flow

## The Config Pipeline

```
User edits UI (SettingsView / SetupWizardView)
    │
    ▼
HavenConfig struct updated in memory
    │
    ▼
ConfigService.save()
    ├── Writes config.json to ~/Library/Application Support/Haven/
    ├── Writes relay list JSON files to relayDataDir/
    └── Updates launch-at-login
    │
    ▼
RelayProcessManager.startRelay(config:)
    ├── generateEnvDictionary(config:) → [String: String]
    ├── For each (key, value): setenv() + SetHavenEnvC(key, value)
    ├── Sets working directory to relayDataDir
    └── Dispatches StartRelayC(false) on background thread
    │
    ▼
Go: StartRelayC() → loadConfig()
    └── godotenv.Load(".env") + os.LookupEnv() for each field
```

## Storage Locations

| What | Path |
|------|------|
| Config JSON | `~/Library/Application Support/Haven/config.json` |
| Relay data dir | `~/Library/Application Support/Haven/haven_database/` |
| .env file | `{relayDataDir}/.env` |
| Import relay list | `{relayDataDir}/relays_import.json` |
| Blastr relay list | `{relayDataDir}/relays_blastr.json` |
| Whitelisted npubs | `{relayDataDir}/whitelisted_npubs.json` |
| Blacklisted npubs | `{relayDataDir}/blacklisted_npubs.json` |
| Databases | `{relayDataDir}/db/{private,chat,outbox,inbox,blossom}/` |
| Blossom blobs | `{relayDataDir}/blossom/` |
| WoT cache | `{relayDataDir}/wot_cache.json` |
| Profile cache | `{relayDataDir}/profiles.json` |
| Relay list cache | `{relayDataDir}/relay_lists.json` |

**Note**: In App Sandbox, `~/Library/Application Support/` is actually `~/Library/Containers/com.bitvora.HavenApp/Data/Library/Application Support/`.

## Swift Config → Env Var → Go Config Mapping

The complete mapping from `HavenConfig` (Swift) → env var name → `Config` struct field (Go):

### Core Settings

| Swift Field | Env Var | Go Field | Default |
|-------------|---------|----------|---------|
| `ownerNpub` | `OWNER_NPUB` | `OwnerNpub` | `""` |
| `relayURL` | `RELAY_URL` | `RelayURL` | `""` |
| `relayPort` | `RELAY_PORT` | `RelayPort` | `3355` |
| `allowNetworkAccess` | `RELAY_BIND_ADDRESS` | `RelayBindAddress` | `"127.0.0.1"` (false) / `"0.0.0.0"` (true) |
| `dbEngine` | `DB_ENGINE` | `DBEngine` | `"badger"` (Swift) / `"lmdb"` (Go) |
| — | `LMDB_MAPSIZE` | `LmdbMapSize` | `0` (auto-detect) |
| `blossomPath` | `BLOSSOM_PATH` | `BlossomPath` | `"blossom/"` → full path in env |
| `logLevel` | `HAVEN_LOG_LEVEL` | `LogLevel` | `"INFO"` |
| — | `DATABASE_PATH` | — | Set to `{relayDataDir}/data/` |
| — | `TZ` | — | Always `"UTC"` |

### Private Relay

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `privateRelayName` | `PRIVATE_RELAY_NAME` | `PrivateRelayName` |
| `ownerNpub` | `PRIVATE_RELAY_NPUB` | `PrivateRelayNpub` |
| `privateRelayDescription` | `PRIVATE_RELAY_DESCRIPTION` | `PrivateRelayDescription` |
| `privateRelayIcon` | `PRIVATE_RELAY_ICON` | `PrivateRelayIcon` |

### Chat Relay

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `chatRelayName` | `CHAT_RELAY_NAME` | `ChatRelayName` |
| `ownerNpub` | `CHAT_RELAY_NPUB` | `ChatRelayNpub` |
| `chatRelayDescription` | `CHAT_RELAY_DESCRIPTION` | `ChatRelayDescription` |
| `chatRelayIcon` | `CHAT_RELAY_ICON` | `ChatRelayIcon` |
| `chatRelayWotDepth` | `WOT_DEPTH` | `WotDepth` |
| `chatRelayMinFollowers` | `WOT_MINIMUM_FOLLOWERS` | `WotMinimumFollowers` |
| `wotRefreshInterval` | `WOT_REFRESH_INTERVAL` | `WotRefreshInterval` |

### Outbox Relay

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `outboxRelayName` | `OUTBOX_RELAY_NAME` | `OutboxRelayName` |
| `ownerNpub` | `OUTBOX_RELAY_NPUB` | `OutboxRelayNpub` |
| `outboxRelayDescription` | `OUTBOX_RELAY_DESCRIPTION` | `OutboxRelayDescription` |
| `outboxRelayIcon` | `OUTBOX_RELAY_ICON` | `OutboxRelayIcon` |

### Inbox Relay

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `inboxRelayName` | `INBOX_RELAY_NAME` | `InboxRelayName` |
| `ownerNpub` | `INBOX_RELAY_NPUB` | `InboxRelayNpub` |
| `inboxRelayDescription` | `INBOX_RELAY_DESCRIPTION` | `InboxRelayDescription` |
| `inboxRelayIcon` | `INBOX_RELAY_ICON` | `InboxRelayIcon` |
| `inboxPullIntervalSeconds` | `INBOX_PULL_INTERVAL_SECONDS` | `InboxPullIntervalSeconds` |

### Import

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `importStartDate` | `IMPORT_START_DATE` | `ImportStartDate` |
| `importSeedRelaysFile` | `IMPORT_SEED_RELAYS_FILE` | → loaded via `getRelayListFromFile()` |
| — | `IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS` | `ImportOwnerNotesFetchTimeoutSeconds` |
| — | `IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS` | `ImportTaggedNotesFetchTimeoutSeconds` |

### Access Control

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `whitelistedNpubsFile` | `WHITELISTED_NPUBS_FILE` | → loaded via `getNpubsFromFile()` → `WhitelistedPubKeys` |
| `blacklistedNpubsFile` | `BLACKLISTED_NPUBS_FILE` | → loaded via `getNpubsFromFile()` → `BlacklistedPubKeys` |

### Backup / Cloud

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `backupProvider` | `BACKUP_PROVIDER` | `BackupProvider` |
| `backupIntervalHours` | `BACKUP_INTERVAL_HOURS` | `BackupIntervalHours` |
| `s3AccessKeyId` | `S3_ACCESS_KEY_ID` | `S3Config.AccessKeyID` |
| `s3SecretKey` | `S3_SECRET_KEY` | `S3Config.SecretKey` |
| `s3Endpoint` | `S3_ENDPOINT` | `S3Config.Endpoint` |
| `s3Region` | `S3_REGION` | `S3Config.Region` |
| `s3BucketName` | `S3_BUCKET_NAME` | `S3Config.BucketName` |

### Broadcasting

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| `blastrRelaysFile` | `BLASTR_RELAYS_FILE` | → loaded via `getRelayListFromFile()` → `BlastrRelays` |

### TLS

| Swift Field | Env Var | Go Field |
|-------------|---------|----------|
| — (platform) | `HAVEN_ENABLE_TLS` | — (checked at runtime) |

Value: `"0"` on macOS, `"1"` on iOS.

### Rate Limiters (hardcoded in `generateEnvDictionary`)

These are not configurable from the UI — they're set as constants in `RelayProcessManager.swift:950-1008`:

| Env Var Pattern | Default |
|-----------------|---------|
| `{RELAY}_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL` | 10-50 |
| `{RELAY}_EVENT_IP_LIMITER_INTERVAL` | 1-60 |
| `{RELAY}_EVENT_IP_LIMITER_MAX_TOKENS` | 20-100 |
| `{RELAY}_ALLOW_EMPTY_FILTERS` | true |
| `{RELAY}_ALLOW_COMPLEX_FILTERS` | true/false |
| `{RELAY}_CONNECTION_RATE_LIMITER_*` | 3/1-5/9 |

## Config Migration Safety

**Critical rule**: every new `HavenConfig` field MUST:
1. Have a default value in the struct declaration
2. Use `decodeIfPresent` with `?? defaults.field` in `init(from:)`
3. Be added to the `CodingKeys` enum

This ensures old `config.json` files load without crashing.

## Recovery Mechanism

If `hasCompletedSetup` is `false` but `.env` exists, `ConfigService` auto-recovers by parsing the `.env` file (`recoverFromEnv()` at line 359). This handles cases where config.json was corrupted but the relay data is intact.
