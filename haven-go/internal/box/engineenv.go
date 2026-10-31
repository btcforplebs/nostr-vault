package box

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
)

// The vault engine is haven-go's own relay (the code the Mac app runs as
// libhaven), configured the way the Mac configures it: environment
// variables plus a few JSON files in its working directory. These values
// mirror HavenApp RelayConfiguration.generateEnvDictionary and HavenConfig's
// defaults, so a box vault behaves as a fresh Mac vault does. Differences
// are on purpose and listed in engineDifferences.

// Mac defaults (HavenConfig.swift).
var (
	macImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://relay.damus.io",
		"wss://relay.btcforplebs.com",
		"wss://nostr-pub.wellorder.net",
	}
	macStarterRelays = []string{
		"wss://relay.primal.net",
		"wss://relay.damus.io",
		"wss://relay.snort.social",
		"wss://relay.btcforplebs.com",
		"wss://nostr-pub.wellorder.net",
	}
)

// engineDifferences documents where the box departs from the Mac's env.
var engineDifferences = map[string]string{
	"RELAY_BIND_ADDRESS":          "127.0.0.1: only the box's front door reaches the engine",
	"NOTIFY_KINDS":                "unset: a box has no screen to notify on",
	"HAVEN_ENABLE_TLS":            "0: the LAN and the mesh reach the front door over plain HTTP, like the Mac",
	"HAVEN_SERVICE_URL_FROM_HOST": "1 without NV_RELAY_URL: NIP-42 AUTH names the address the client used (LAN IP, hostname, mesh), not 127.0.0.1",
}

// EngineEnv is the engine's environment for a vault in vaultDir.
func EngineEnv(c Config, vaultDir string) map[string]string {
	owner := c.OwnerNpub
	env := map[string]string{
		"OWNER_NPUB":         owner,
		"RELAY_URL":          c.RelayURL,
		"RELAY_PORT":         strconv.Itoa(c.EnginePort),
		"RELAY_BIND_ADDRESS": "127.0.0.1",
		"DB_ENGINE":          "badger", // the Mac's engine (libhaven has no LMDB)
		"LMDB_MAPSIZE":       "0",
		"DATABASE_PATH":      filepath.Join(vaultDir, "data") + "/",
		"BLOSSOM_PATH":       filepath.Join(vaultDir, "blossom") + "/",
		"HAVEN_LOG_LEVEL":    "INFO",

		"WHITELISTED_NPUBS_FILE": "whitelisted_npubs.json",
		"BLACKLISTED_NPUBS_FILE": "blacklisted_npubs.json",

		"PRIVATE_RELAY_NAME":                                        "Nostr Vault Private",
		"PRIVATE_RELAY_NPUB":                                        owner,
		"PRIVATE_RELAY_DESCRIPTION":                                 "My private Nostr Vault relay",
		"PRIVATE_RELAY_ICON":                                        "",
		"PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL":        "50",
		"PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL":                   "1",
		"PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS":                 "100",
		"PRIVATE_RELAY_ALLOW_EMPTY_FILTERS":                         "true",
		"PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS":                       "true",
		"PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
		"PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL":            "5",
		"PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS":          "9",

		"CHAT_RELAY_NAME":                                        "Nostr Vault Chat",
		"CHAT_RELAY_NPUB":                                        owner,
		"CHAT_RELAY_DESCRIPTION":                                 "Private chat relay",
		"CHAT_RELAY_ICON":                                        "",
		"CHAT_RELAY_WOT_DEPTH":                                   "3",
		"CHAT_RELAY_WOT_REFRESH_INTERVAL_HOURS":                  "24",
		"WOT_REFRESH_INTERVAL":                                   "24h",
		"WOT_DEPTH":                                              "3",
		"WOT_MINIMUM_FOLLOWERS":                                  "3",
		"CHAT_RELAY_MINIMUM_FOLLOWERS":                           "3",
		"CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL":        "50",
		"CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL":                   "1",
		"CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS":                 "100",
		"CHAT_RELAY_ALLOW_EMPTY_FILTERS":                         "true",
		"CHAT_RELAY_ALLOW_COMPLEX_FILTERS":                       "false",
		"CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
		"CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL":            "3",
		"CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS":          "9",

		"OUTBOX_RELAY_NAME":                                        "Nostr Vault Public",
		"OUTBOX_RELAY_NPUB":                                        owner,
		"OUTBOX_RELAY_DESCRIPTION":                                 "Public outbox relay",
		"OUTBOX_RELAY_ICON":                                        "",
		"OUTBOX_MAX_EVENTS_PER_MINUTE":                             "100",
		"OUTBOX_MAX_CONNECTIONS_PER_MINUTE":                        "5",
		"OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL":        "10",
		"OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL":                   "60",
		"OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS":                 "100",
		"OUTBOX_RELAY_ALLOW_EMPTY_FILTERS":                         "true",
		"OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS":                       "false",
		"OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
		"OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL":            "1",
		"OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS":          "9",

		"INBOX_RELAY_NAME":                                        "Nostr Vault Inbox",
		"INBOX_RELAY_NPUB":                                        owner,
		"INBOX_RELAY_DESCRIPTION":                                 "Personal inbox relay",
		"INBOX_RELAY_ICON":                                        "",
		"INBOX_PULL_INTERVAL_SECONDS":                             "900",
		"INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL":        "10",
		"INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL":                   "1",
		"INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS":                 "20",
		"INBOX_RELAY_ALLOW_EMPTY_FILTERS":                         "true",
		"INBOX_RELAY_ALLOW_COMPLEX_FILTERS":                       "false",
		"INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
		"INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL":            "1",
		"INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS":          "9",

		"IMPORT_START_DATE":                         "2023-01-01",
		"IMPORT_SEED_RELAYS_FILE":                   "relays_import.json",
		"IMPORT_QUERY_INTERVAL_SECONDS":             "600",
		"IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS":  "300",
		"IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS": "600",
		"DM_RELAYS_FILE":                            "relays_dm.json",
		"MAC_RELAY_URL":                             "",

		"BACKUP_PROVIDER":       "none",
		"BACKUP_INTERVAL_HOURS": "24",

		"BLASTR_RELAYS_FILE":          "relays_blastr.json",
		"WOT_FETCH_TIMEOUT_SECONDS":   "60",
		"HAVEN_ENABLE_TLS":            "0",
		"HAVEN_SERVICE_URL_FROM_HOST": "1",
	}
	return env
}

// EngineEnvList is EngineEnv as KEY=VALUE pairs, sorted, for exec. Box-only
// NV_* settings and anything secret are never passed on: the engine gets a
// clean environment plus PATH/HOME/TZ.
func EngineEnvList(c Config, vaultDir string, getenv func(string) string) []string {
	env := EngineEnv(c, vaultDir)
	for _, k := range []string{"PATH", "HOME", "TZ"} {
		if v := getenv(k); v != "" {
			env[k] = v
		}
	}
	// S3 backups, when the installer set them, pass through under the
	// engine's own names.
	if p := getenv("NV_BACKUP_PROVIDER"); p != "" {
		env["BACKUP_PROVIDER"] = p
		for _, k := range []string{"S3_ACCESS_KEY_ID", "S3_SECRET_KEY", "S3_ENDPOINT", "S3_REGION", "S3_BUCKET_NAME"} {
			if v := getenv("NV_" + k); v != "" {
				env[k] = v
			}
		}
	}
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

// WriteEngineFiles writes the JSON files the engine reads from its working
// directory. Existing relay lists are kept (an owner may have edited them);
// the owner whitelist is always rewritten from NV_OWNER.
func WriteEngineFiles(c Config, vaultDir string) error {
	if err := os.MkdirAll(vaultDir, 0o700); err != nil {
		return err
	}
	write := func(name string, v any, keep bool) error {
		path := filepath.Join(vaultDir, name)
		if keep {
			if _, err := os.Stat(path); err == nil {
				return nil
			}
		}
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(path, b, 0o600); err != nil {
			return fmt.Errorf("writing %s: %w", name, err)
		}
		return nil
	}
	if err := write("whitelisted_npubs.json", []string{c.OwnerNpub}, false); err != nil {
		return err
	}
	if err := write("blacklisted_npubs.json", []string{}, true); err != nil {
		return err
	}
	if err := write("relays_import.json", macImportSeedRelays, true); err != nil {
		return err
	}
	if err := write("relays_blastr.json", macStarterRelays, true); err != nil {
		return err
	}
	return write("relays_dm.json", []string{}, true)
}
