package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/joho/godotenv"
	"github.com/nbd-wtf/go-nostr/nip19"
)

type S3Config struct {
	AccessKeyID string `json:"access_key_id"`
	SecretKey   string `json:"secret_key"`
	Endpoint    string `json:"endpoint"`
	BucketName  string `json:"bucket_name"`
	Region      string `json:"region"`
}

type Config struct {
	OwnerNpub                            string              `json:"owner_npub"`
	OwnerPubKey                          string              `json:"owner_pubkey"`
	DBEngine                             string              `json:"db_engine"`
	LmdbMapSize                          int64               `json:"lmdb_map_size"`
	BlossomPath                          string              `json:"blossom_path"`
	RelayURL                             string              `json:"relay_url"`
	RelayPort                            int                 `json:"relay_port"`
	RelayBindAddress                     string              `json:"relay_bind_address"`
	RelaySoftware                        string              `json:"relay_software"`
	RelayVersion                         string              `json:"relay_version"`
	UserAgent                            string              `json:"user_agent"`
	PrivateRelayName                     string              `json:"private_relay_name"`
	PrivateRelayNpub                     string              `json:"private_relay_npub"`
	PrivateRelayDescription              string              `json:"private_relay_description"`
	PrivateRelayIcon                     string              `json:"private_relay_icon"`
	ChatRelayName                        string              `json:"chat_relay_name"`
	ChatRelayNpub                        string              `json:"chat_relay_npub"`
	ChatRelayDescription                 string              `json:"chat_relay_description"`
	ChatRelayIcon                        string              `json:"chat_relay_icon"`
	OutboxRelayName                      string              `json:"outbox_relay_name"`
	OutboxRelayNpub                      string              `json:"outbox_relay_npub"`
	OutboxRelayDescription               string              `json:"outbox_relay_description"`
	OutboxRelayIcon                      string              `json:"outbox_relay_icon"`
	InboxRelayName                       string              `json:"inbox_relay_name"`
	InboxRelayNpub                       string              `json:"inbox_relay_npub"`
	InboxRelayDescription                string              `json:"inbox_relay_description"`
	InboxRelayIcon                       string              `json:"inbox_relay_icon"`
	InboxPullIntervalSeconds             int                 `json:"inbox_pull_interval_seconds"`
	ImportStartDate                      string              `json:"import_start_date"`
	ImportOwnerNotesFetchTimeoutSeconds  int                 `json:"import_owned_notes_fetch_timeout_seconds"`
	ImportTaggedNotesFetchTimeoutSeconds int                 `json:"import_tagged_fetch_timeout_seconds"`
	ImportSeedRelays                     []string            `json:"import_seed_relays"`
	DmRelays                             []string            `json:"dm_relays"`
	BackupProvider                       string              `json:"backup_provider"`
	BackupIntervalHours                  int                 `json:"backup_interval_hours"`
	WotDepth                             int                 `json:"wot_depth"`
	WotMinimumFollowers                  int                 `json:"wot_minimum_followers"`
	WotFetchTimeoutSeconds               int                 `json:"wot_fetch_timeout_seconds"`
	WotRefreshInterval                   time.Duration       `json:"wot_refresh_interval"`
	WotCachePath                         string              `json:"wot_cache_path"`
	WotCacheTTLMinutes                   int                 `json:"wot_cache_ttl_minutes"`
	WhitelistedPubKeys                   map[string]struct{} `json:"whitelisted_pubkeys"`
	BlacklistedPubKeys                   map[string]struct{} `json:"blacklisted_pubkeys"`
	LogLevel                             string              `json:"log_level"`
	BlastrRelays                         []string            `json:"blastr_relays"`
	BlastrTimeoutSeconds                 int                 `json:"blastr_timeout_seconds"`
	S3Config                             *S3Config           `json:"s3_config"`
	NegentropySyncEnabled                bool                `json:"negentropy_sync_enabled"`
	NegentropyServeEnabled               bool                `json:"negentropy_serve_enabled"`
	SyncWindowDays                       int                 `json:"sync_window_days"`
	TombstonePath                        string              `json:"tombstone_path"`
	NotifyBatchLimit                     int                 `json:"notify_batch_limit"`
	NotifyMaxAgeHours                    int                 `json:"notify_max_age_hours"`
	FeedSyncEnabled                      bool                `json:"feed_sync_enabled"`
	FeedSyncWindowDays                   int                 `json:"feed_sync_window_days"`
	FeedSyncRelays                       []string            `json:"feed_sync_relays"`
	GoMemLimitMB                         int                 `json:"go_mem_limit_mb"`
	PopularTallyEnabled                  bool                `json:"popular_tally_enabled"`
	PopularTallyCachePath                string              `json:"popular_tally_cache_path"`
}

const relaySoftware = "https://github.com/barrydeen/haven"

func loadConfig() Config {
	_ = godotenv.Load(".env")

	defaultWotDepth := 3
	if runtime.GOOS == "ios" || runtime.GOOS == "android" {
		defaultWotDepth = 2 // Level 3 is too heavy for mobile OOM
	}

	cfg := Config{
		OwnerNpub:                            getEnv("OWNER_NPUB"),
		OwnerPubKey:                          nPubToPubkey(getEnv("OWNER_NPUB")),
		DBEngine:                             getEnvString("DB_ENGINE", "lmdb"),
		LmdbMapSize:                          getEnvInt64("LMDB_MAPSIZE", 0),
		BlossomPath:                          getEnvString("BLOSSOM_PATH", "blossom"),
		RelayURL:                             getEnv("RELAY_URL"),
		RelayPort:                            getEnvInt("RELAY_PORT", 3355),
		RelayBindAddress:                     getEnvString("RELAY_BIND_ADDRESS", "0.0.0.0"),
		RelaySoftware:                        relaySoftware,
		RelayVersion:                         getVersion(),
		UserAgent:                            fmt.Sprintf("Haven/%s (+%s)", getVersion(), relaySoftware),
		PrivateRelayName:                     getEnv("PRIVATE_RELAY_NAME"),
		PrivateRelayNpub:                     getEnv("PRIVATE_RELAY_NPUB"),
		PrivateRelayDescription:              getEnv("PRIVATE_RELAY_DESCRIPTION"),
		PrivateRelayIcon:                     getEnv("PRIVATE_RELAY_ICON"),
		ChatRelayName:                        getEnv("CHAT_RELAY_NAME"),
		ChatRelayNpub:                        getEnv("CHAT_RELAY_NPUB"),
		ChatRelayDescription:                 getEnv("CHAT_RELAY_DESCRIPTION"),
		ChatRelayIcon:                        getEnv("CHAT_RELAY_ICON"),
		OutboxRelayName:                      getEnv("OUTBOX_RELAY_NAME"),
		OutboxRelayNpub:                      getEnv("OUTBOX_RELAY_NPUB"),
		OutboxRelayDescription:               getEnv("OUTBOX_RELAY_DESCRIPTION"),
		OutboxRelayIcon:                      getEnv("OUTBOX_RELAY_ICON"),
		InboxRelayName:                       getEnv("INBOX_RELAY_NAME"),
		InboxRelayNpub:                       getEnv("INBOX_RELAY_NPUB"),
		InboxRelayDescription:                getEnv("INBOX_RELAY_DESCRIPTION"),
		InboxRelayIcon:                       getEnv("INBOX_RELAY_ICON"),
		InboxPullIntervalSeconds:             getEnvInt("INBOX_PULL_INTERVAL_SECONDS", 3600),
		ImportStartDate:                      getEnv("IMPORT_START_DATE"),
		ImportOwnerNotesFetchTimeoutSeconds:  getEnvInt("IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS", 60),
		ImportTaggedNotesFetchTimeoutSeconds: getEnvInt("IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS", 120),
		ImportSeedRelays:                     getRelayListFromFile(getEnv("IMPORT_SEED_RELAYS_FILE")),
		DmRelays:                             getRelayListFromFile(getEnvString("DM_RELAYS_FILE", "")),
		BackupProvider:                       getEnvString("BACKUP_PROVIDER", "none"),
		BackupIntervalHours:                  getEnvInt("BACKUP_INTERVAL_HOURS", 24),
		WotDepth:                             getEnvInt("WOT_DEPTH", defaultWotDepth),
		WotMinimumFollowers:                  getEnvInt("WOT_MINIMUM_FOLLOWERS", 0),
		WotFetchTimeoutSeconds:               getEnvInt("WOT_FETCH_TIMEOUT_SECONDS", 30),
		WotRefreshInterval:                   getEnvDuration("WOT_REFRESH_INTERVAL", 24*time.Hour),
		WotCachePath:                         getEnvString("WOT_CACHE_PATH", "wot_cache.json"),
		WotCacheTTLMinutes:                   getEnvInt("WOT_CACHE_TTL_MINUTES", 4320),
		WhitelistedPubKeys:                   getNpubsFromFile(getEnvString("WHITELISTED_NPUBS_FILE", "")),
		BlacklistedPubKeys:                   getNpubsFromFile(getEnvString("BLACKLISTED_NPUBS_FILE", "")),
		LogLevel:                             getEnvString("HAVEN_LOG_LEVEL", "INFO"),
		BlastrRelays:                         getRelayListFromFile(getEnv("BLASTR_RELAYS_FILE")),
		BlastrTimeoutSeconds:                 getEnvInt("BLASTR_TIMEOUT_SECONDS", 5),
		S3Config:                             getS3Config(),
		NegentropySyncEnabled:                getEnvBool("NEGENTROPY_SYNC_ENABLED", true),
		NegentropyServeEnabled:               getEnvBool("NEGENTROPY_SERVE_ENABLED", true),
		SyncWindowDays:                       getEnvInt("SYNC_WINDOW_DAYS", 30),
		TombstonePath:                        getEnvString("TOMBSTONE_PATH", "db/tombstones.jsonl"),
		NotifyBatchLimit:                     getEnvInt("NOTIFY_BATCH_LIMIT", 5),
		NotifyMaxAgeHours:                    getEnvInt("NOTIFY_MAX_AGE_HOURS", 24),
		FeedSyncEnabled:                      getEnvBool("FEED_SYNC_ENABLED", true),
		FeedSyncWindowDays:                   getEnvInt("FEED_SYNC_WINDOW_DAYS", 7),
		FeedSyncRelays:                       getRelayListFromFile(getEnvString("FEED_SYNC_RELAYS_FILE", "")),
		GoMemLimitMB:                         getEnvInt("GO_MEM_LIMIT_MB", defaultGoMemLimitMB()),
		PopularTallyEnabled:                  getEnvBool("POPULAR_TALLY_ENABLED", true),
		PopularTallyCachePath:                getEnvString("POPULAR_TALLY_CACHE_PATH", "popular_tally.json"),
	}

	// Relay owner is always whitelisted
	if cfg.OwnerPubKey != "" {
		cfg.WhitelistedPubKeys[cfg.OwnerPubKey] = struct{}{}
	}

	// Clamp the catch-up interval regardless of which host app passed it in:
	// no UI exposes it, so anything below 5 min is a legacy save (the old 60s
	// default) — short enough that sync rounds run back-to-back once the DBs
	// grow, the 100% CPU treadmill. ≤0 means unset; use sites default it.
	if cfg.InboxPullIntervalSeconds > 0 && cfg.InboxPullIntervalSeconds < 300 {
		cfg.InboxPullIntervalSeconds = 300
	}

	applyGoMemLimit(cfg.GoMemLimitMB)

	return cfg

}

// defaultGoMemLimitMB picks a soft Go heap target per platform. The embedded
// builds share the host app's footprint budget (jetsam on iOS, user-visible
// Activity Monitor numbers on macOS); a standalone server gets no limit.
func defaultGoMemLimitMB() int {
	switch runtime.GOOS {
	case "ios", "android":
		return 256
	case "darwin":
		// Roomy on purpose: sync rounds legitimately spike (vector builds over
		// six Badger DBs), and a limit the live heap can approach turns into
		// back-to-back GC cycles — sustained 100% CPU with no crash.
		return 1024
	default:
		return 0 // server: let GOGC alone govern
	}
}

// applyGoMemLimit sets the runtime's soft memory limit (GOMEMLIMIT). Without
// it, sync/import spikes grow the heap and darwin's lazy page reclaim
// (MADV_FREE) keeps the peak visible as resident memory indefinitely.
// 0 or negative disables (resets to the effectively-unlimited default).
func applyGoMemLimit(mb int) {
	if mb <= 0 {
		debug.SetMemoryLimit(math.MaxInt64)
		return
	}
	debug.SetMemoryLimit(int64(mb) << 20)
}

func getVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "(devel)"
	}
	return info.Main.Version
}

func getS3Config() *S3Config {
	backupProvider := getEnvString("BACKUP_PROVIDER", "none")

	if backupProvider == "s3" {
		return &S3Config{
			AccessKeyID: getEnv("S3_ACCESS_KEY_ID"),
			SecretKey:   getEnv("S3_SECRET_KEY"),
			Endpoint:    getEnv("S3_ENDPOINT"),
			BucketName:  getEnv("S3_BUCKET_NAME"),
			Region:      getEnv("S3_REGION"),
		}
	}

	return nil
}

func getRelayListFromFile(filePath string) []string {
	if filePath == "" {
		return []string{}
	}
	file, err := os.ReadFile(filePath)
	if err != nil {
		log.Printf("⚠️ Failed to read relay list file %s: %s", filePath, err)
		return []string{}
	}

	var relayList []string
	if err := json.Unmarshal(file, &relayList); err != nil {
		log.Printf("⚠️ Failed to parse relay list JSON from %s: %s", filePath, err)
		return []string{}
	}

	for i, relay := range relayList {
		relay = strings.TrimSpace(relay)
		if !strings.HasPrefix(relay, "wss://") && !strings.HasPrefix(relay, "ws://") {
			relay = "wss://" + relay
		}
		relayList[i] = relay
	}
	return relayList
}

func getNpubsFromFile(filePath string) map[string]struct{} {
	pubKeys := map[string]struct{}{}
	if filePath == "" {
		// No pubKeys file, only owner will be whitelisted
		return pubKeys
	}
	file, err := os.ReadFile(filePath)
	if err != nil {
		log.Printf("⚠️ Failed to read npubs file %s: %s", filePath, err)
		return pubKeys
	}

	var npubs []string
	if err := json.Unmarshal(file, &npubs); err != nil {
		log.Printf("⚠️ Failed to parse npubs JSON from %s: %s", filePath, err)
		return pubKeys
	}

	for _, npub := range npubs {
		npub = strings.TrimSpace(npub)
		pk := nPubToPubkey(npub)
		if pk != "" {
			pubKeys[pk] = struct{}{}
		}
	}
	return pubKeys
}

// blacklistOverride lets the client push a live update to the blacklist
// without restarting the relay. config.BlacklistedPubKeys itself is only
// ever populated once, from BLACKLISTED_NPUBS_FILE at config-load time — so
// blocking someone mid-session (the client-side "Block" action) previously
// had no way to take effect at the relay level until the next app launch. In
// the meantime the relay kept importing and notifying about that pubkey's
// activity, which the client's own feed/vault filters correctly hid
// everywhere — exactly the "red dot fires, nothing in any filter" symptom.
// An atomic pointer swap (mirroring pkg/wot's pattern) rather than a mutex
// since this is read on every tagged/whitelisted event across many goroutines
// and written rarely (only when the user blocks/unblocks someone).
var blacklistOverride atomic.Pointer[map[string]struct{}]

// isBlacklisted checks the live override if one has been pushed, falling back
// to the blacklist loaded from BLACKLISTED_NPUBS_FILE at startup. All
// blacklist checks should go through this rather than reading
// config.BlacklistedPubKeys directly, so a live update actually takes effect.
func isBlacklisted(pubkey string) bool {
	if m := blacklistOverride.Load(); m != nil {
		_, ok := (*m)[pubkey]
		return ok
	}
	_, ok := config.BlacklistedPubKeys[pubkey]
	return ok
}

// UpdateBlacklist atomically replaces the live blacklist. Called whenever the
// client blocks/unblocks a pubkey, on any account — takes effect on the very
// next event processed, no relay restart required.
func UpdateBlacklist(pubkeys map[string]struct{}) {
	blacklistOverride.Store(&pubkeys)
}

func getEnv(key string) string {
	value, exists := os.LookupEnv(key)
	if !exists {
		log.Printf("⚠️ Environment variable %s not set", key)
		return ""
	}
	return value
}

func getEnvString(key string, defaultValue string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return defaultValue
}

// The typed getters below fall back to their default on a malformed value
// rather than panicking. In the embedded (c-archive) builds there is no
// separate relay process to lose: an unrecovered panic prints to stderr and
// exits the whole host app — which, because it is a clean exit rather than a
// signal, produces no crash report at all. The macOS app was observed dying
// ~2s after launch with no crash log and never binding its port, from exactly
// this path. A single stray character in .env must not be able to do that.
// Same reasoning as the "never calls os.Exit" note in import.go.
func badEnv(key, value string, err error, fallback any) {
	log.Printf("⚠️ %s=%q is not valid (%v) — using default %v", key, value, err, fallback)
}

func getEnvInt(key string, defaultValue int) int {
	if value, ok := os.LookupEnv(key); ok {
		intValue, err := strconv.Atoi(value)
		if err != nil {
			badEnv(key, value, err, defaultValue)
			return defaultValue
		}
		return intValue
	}
	return defaultValue
}

func getEnvInt64(key string, defaultValue int64) int64 {
	if value, ok := os.LookupEnv(key); ok {
		intValue, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			badEnv(key, value, err, defaultValue)
			return defaultValue
		}
		return intValue
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	if value, ok := os.LookupEnv(key); ok {
		boolValue, err := strconv.ParseBool(value)
		if err != nil {
			badEnv(key, value, err, defaultValue)
			return defaultValue
		}
		return boolValue
	}
	return defaultValue
}

func getEnvDuration(key string, defaultValue time.Duration) time.Duration {
	if value, ok := os.LookupEnv(key); ok {
		durationValue, err := time.ParseDuration(value)
		if err != nil {
			badEnv(key, value, err, defaultValue)
			return defaultValue
		}
		return durationValue
	}
	return defaultValue
}

func nPubToPubkey(nPub string) string {
	if nPub == "" {
		return ""
	}
	_, v, err := nip19.Decode(nPub)
	if err != nil {
		log.Printf("⚠️ invalid npub %q: %v", nPub, err)
		return ""
	}
	s, ok := v.(string)
	if !ok {
		log.Printf("⚠️ npub decoded to non-string type: %T", v)
		return ""
	}
	return s
}

var art = `
██╗  ██╗ █████╗ ██╗   ██╗███████╗███╗   ██╗
██║  ██║██╔══██╗██║   ██║██╔════╝████╗  ██║
███████║███████║██║   ██║█████╗  ██╔██╗ ██║
██╔══██║██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║
██║  ██║██║  ██║ ╚████╔╝ ███████╗██║ ╚████║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝
HIGH AVAILABILITY VAULT FOR EVENTS ON NOSTR
	`
