//go:build cshared

package main

import "C"

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"log/slog"
	"math/bits"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
	"github.com/mailru/easyjson"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
	"github.com/nbd-wtf/go-nostr/nip44"
	"github.com/nbd-wtf/go-nostr/nip46"
	"github.com/spf13/afero"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/scrypt"
)

// Import log bridge: lets the host app poll for Go log messages during import.
var importLogLatest atomic.Value // stores string

// Notification bridge: a non-lossy FIFO of "🔔NOTIFY|..." marker lines. The
// import log above keeps only the LATEST message, so amid the relay's constant
// logging an inbound-event marker is usually overwritten before the host polls.
// Notifications must never be dropped, so they get their own bounded queue that
// is drained line-by-line via GetNotifyLogC.
const notifyMarker = "🔔NOTIFY|"
const notifyQueueMax = 512

var (
	notifyQueueMu sync.Mutex
	notifyQueue   []string
)

func pushNotify(msg string) {
	notifyQueueMu.Lock()
	defer notifyQueueMu.Unlock()
	if len(notifyQueue) >= notifyQueueMax {
		notifyQueue = notifyQueue[1:] // drop oldest to bound memory
	}
	notifyQueue = append(notifyQueue, msg)
}

// importLogWriter intercepts log.Println output and stores the latest message
// so the host app (Android/iOS) can poll for progress updates.
type importLogWriter struct {
	original io.Writer
}

func (w *importLogWriter) Write(p []byte) (n int, err error) {
	msg := strings.TrimSpace(string(p))
	if msg != "" {
		// Route notification markers to the dedicated (non-lossy) queue and keep
		// them out of the user-facing console log; everything else feeds the
		// best-effort latest-message import log.
		if strings.Contains(msg, notifyMarker) {
			pushNotify(msg)
		} else {
			importLogLatest.Store(msg)
		}
	}
	return w.original.Write(p)
}

//export GetImportLogC
func GetImportLogC() *C.char {
	val := importLogLatest.Load()
	if val == nil {
		return nil
	}
	msg, ok := val.(string)
	if !ok || msg == "" {
		return nil
	}
	// Consume on read so the same message isn't returned twice
	importLogLatest.Store("")
	return C.CString(msg)
}

//export GetNotifyLogC
func GetNotifyLogC() *C.char {
	notifyQueueMu.Lock()
	defer notifyQueueMu.Unlock()
	if len(notifyQueue) == 0 {
		return nil
	}
	msg := notifyQueue[0]
	notifyQueue = notifyQueue[1:]
	return C.CString(msg)
}

// NIP-46 remote signer state (independent of relay lifecycle)
var (
	nip46Ctx    context.Context
	nip46Cancel context.CancelFunc
	nip46Pool   *nostr.SimplePool
	nip46Client *nip46.BunkerClient
	nip46Mu     sync.RWMutex

	nip46PendingAuthURL atomic.Value // stores string
)

func isCShared() bool {
	return true
}

//export SetHavenEnvC
func SetHavenEnvC(key *C.char, value *C.char) {
	os.Setenv(C.GoString(key), C.GoString(value))
}

// prepareCSharedEnv performs the per-start environment setup shared by
// normal and import mode. Must be called with relayLC.mu held — it
// mutates the package globals config/fs and the process CWD.
func prepareCSharedEnv() error {
	// On Android (and other embedded hosts), the process CWD is NOT the relay
	// data directory.  DATABASE_PATH is set to <relayDataDir>/data/ — derive
	// the relay data root and chdir so that relative paths (db/*, wot_cache.json,
	// relays_*.json) resolve correctly, matching the iOS subprocess behaviour.
	if dbPath := os.Getenv("DATABASE_PATH"); dbPath != "" {
		relayRoot := filepath.Dir(strings.TrimRight(dbPath, "/"))
		if err := os.Chdir(relayRoot); err != nil {
			log.Printf("⚠️ Failed to chdir to relay data root %s: %v", relayRoot, err)
		} else {
			log.Printf("📂 CWD set to relay data root: %s", relayRoot)
		}
	}

	config = loadConfig() // reload config dynamically

	nostr.InfoLogger = log.New(io.Discard, "", 0)
	slog.SetLogLoggerLevel(getLogLevelFromConfig())

	fs = afero.NewOsFs()
	if err := fs.MkdirAll(config.BlossomPath, 0755); err != nil {
		return fmt.Errorf("error creating blossom path: %w", err)
	}

	// Install log interceptor so the host app can poll for log messages.
	// This runs in both normal and import mode, enabling the dashboard
	// console log viewer on Android/iOS. Only install once — wrapping on
	// every restart would nest writers and duplicate captured lines.
	if _, ok := log.Writer().(*importLogWriter); !ok {
		log.SetOutput(&importLogWriter{original: log.Writer()})
	}

	return nil
}

//export StartRelayC
func StartRelayC(importMode bool) {
	// Recover from any panic so we don't crash the host app
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 HAVEN recovered from panic: %v", r)
		}
	}()

	if importMode {
		runImportCycle()
		return
	}

	err := relayLC.startCycle(func(cycle *relayCycle) error {
		if err := prepareCSharedEnv(); err != nil {
			return err
		}

		cycle.pool = nostr.NewSimplePool(cycle.ctx,
			nostr.WithPenaltyBox(),
			nostr.WithRelayOptions(
				nostr.WithRequestHeader{
					"User-Agent": []string{config.UserAgent},
				}),
		)
		pool = cycle.pool // shared code (blast, import.go) reads the global

		log.Println("🚀 HAVEN", config.RelayVersion, "is booting up (C-Shared Mode) [1/3]")

		log.Println("⏳ Loading databases [2/3]")
		if err := initRelays(cycle.ctx); err != nil {
			return fmt.Errorf("error initializing databases/relays: %w", err)
		}
		log.Println("✅ Databases ready")

		log.Println("⏳ Starting background services [3/3]")
		cycle.spawn("background-setup", func() {
			// Initialize WOT (can take time, so run in background)
			log.Println("  → Initializing Web of Trust")
			wotModel := wot.NewSimpleInMemory(
				cycle.pool,
				config.WhitelistedPubKeys,
				config.ImportSeedRelays,
				config.WotDepth,
				config.WotMinimumFollowers,
				config.WotFetchTimeoutSeconds,
				config.WotCachePath,
				config.WotCacheTTLMinutes,
			).WithFallbackSeeds(loadStarterPack())

			// Try to load from cache first - instant startup
			// Only run full network rebuild if cache is missing or expired
			cacheLoaded, cacheAgeMinutes := wotModel.LoadFromCache()
			gate := wot.NewCycle()
			if cacheLoaded {
				wot.MarkReady(gate, wotModel)
				log.Println("  ✓ Web of Trust loaded from cache, skipping rebuild")

				// wot.PeriodicRefresh's ticker (spawned below) only fires after a
				// full WotRefreshInterval of continuous uptime, which this app may
				// never accumulate. Check the cache's actual age against the same
				// interval here so a WoT that's due for a refresh doesn't sit
				// stale for the full WotCacheTTLMinutes — e.g. a cache computed
				// while the follow list was briefly clobbered by an unrelated bug
				// would otherwise keep silently rejecting real replies/reactions
				// as "not in WoT" until the TTL fully expired.
				if time.Duration(cacheAgeMinutes)*time.Minute >= config.WotRefreshInterval {
					log.Println("  🔄 WoT cache is due for a refresh, updating in the background")
					cycle.spawn("wot.Refresh.stale", func() { wotModel.Refresh(cycle.ctx) })
				}
			} else {
				cycle.spawn("wot.Initialize", func() { wot.Initialize(cycle.ctx, wotModel, gate) })
				log.Println("  ✓ Web of Trust initializing from network")
			}

			cycle.spawn("subscribeInboxAndChat", func() { subscribeInboxAndChat(cycle.ctx) })
			cycle.spawn("syncFeed", func() { syncFeed(cycle.ctx) })
			cycle.spawn("ingestPopularEngagement", func() { ingestPopularEngagement(cycle.ctx) })
			cycle.spawn("periodicCloudBackups", func() { startPeriodicCloudBackups(cycle.ctx) })
			cycle.spawn("wot.PeriodicRefresh", func() { wot.PeriodicRefresh(cycle.ctx, config.WotRefreshInterval) })
		})

		// Use a fresh ServeMux each cycle so stop/start never panics on
		// duplicate pattern registration in the default mux.
		mux := http.NewServeMux()
		mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("templates/static"))))

		// All Blossom endpoints (PUT /upload, GET /<sha256>, DELETE /<sha256>, etc.)
		// are handled by the khatru/blossom server mounted on outboxRelay in init.go.
		// We just need to route everything through dynamicRelayHandler and add CORS headers.
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "*")

			if r.Method == "OPTIONS" {
				w.WriteHeader(http.StatusOK)
				return
			}

			dynamicRelayHandler(w, r)
		})

		addr := net.JoinHostPort(config.RelayBindAddress, strconv.Itoa(config.RelayPort))
		cycle.server = &http.Server{Addr: addr, Handler: mux}

		// Only enable HTTPS when HAVEN_ENABLE_TLS=1 (iOS needs it for App Transport Security;
		// macOS uses plain HTTP since Cloudflare handles TLS termination)
		var certPath, keyPath string
		if os.Getenv("HAVEN_ENABLE_TLS") == "1" {
			var err error
			certPath, keyPath, err = getOrCreateSelfSignedCert(".")
			if err != nil {
				log.Printf("⚠️  Failed to setup HTTPS certificate: %v, falling back to HTTP", err)
				certPath, keyPath = "", ""
			} else {
				log.Printf("🔐 HTTPS enabled with self-signed certificate")
			}
		}

		// Start server in background and give it a moment to bind before continuing
		cycle.spawn("http-server", func() {
			var err error
			if certPath != "" && keyPath != "" {
				err = cycle.server.ListenAndServeTLS(certPath, keyPath)
			} else {
				err = cycle.server.ListenAndServe()
			}
			if err != nil && err != http.ErrServerClosed {
				// e.g. "bind: address already in use" — the host app's log
				// parser watches for this to surface port conflicts.
				log.Printf("🚫 relay HTTP server exited: %v", err)
			}
		})

		// Brief delay to ensure server binds to port before returning
		time.Sleep(100 * time.Millisecond)

		protocol := "http"
		if certPath != "" {
			protocol = "https"
		}
		log.Printf("🔗 listening at %s://%s", protocol, addr)
		return nil
	})

	switch {
	case err == errAlreadyRunning:
		log.Println("⚠️ StartRelayC ignored: relay already running")
	case err != nil:
		log.Println("🚫", err)
		// initRelays may have opened some DBs before failing
		CloseDBs()
	}
}

// runImportCycle runs a one-shot import under the lifecycle mutex so it
// can never overlap a normal relay cycle. The cycle is installed in
// relayLC.current before the import starts so StopRelayC's lock-free
// cancel phase can abort a long-running import.
func runImportCycle() {
	relayLC.mu.Lock()
	defer relayLC.mu.Unlock()
	if relayLC.current.Load() != nil {
		log.Println("⚠️ Import ignored: relay already running")
		return
	}

	if err := prepareCSharedEnv(); err != nil {
		log.Println("🚫", err)
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	c := &relayCycle{ctx: ctx, cancel: cancel}
	c.pool = nostr.NewSimplePool(ctx,
		nostr.WithPenaltyBox(),
		nostr.WithRelayOptions(
			nostr.WithRequestHeader{
				"User-Agent": []string{config.UserAgent},
			}),
	)
	pool = c.pool
	relayLC.current.Store(c)
	defer func() {
		relayLC.current.Swap(nil)
		cancel()
		CloseDBs()
	}()

	log.Println("🚀 HAVEN", config.RelayVersion, "is booting up (C-Shared Import Mode)")
	if !ensureImportRelays() {
		log.Println("🚫 Import aborted: could not connect to any seed relays")
		return
	}
	runImport(ctx)
	if ctx.Err() != nil {
		log.Println("🛑 Import cancelled")
		return
	}
	log.Println("✅ Import completed in C-Shared mode")
}

//export StopRelayC
func StopRelayC() {
	log.Println("🔌 HAVEN is shutting down (C-Shared Mode)")
	relayLC.stopCycle(func(c *relayCycle) {
		if c.server != nil {
			// Use a bounded timeout so a hung handler can't block shutdown
			// forever. The whole stop sequence (server drain + goroutine wait
			// + DB close) must finish inside ~5 s: Android imposes a 5 s JNI
			// timeout, and iOS SIGKILLs the app (0x8BADF00D) if termination
			// takes longer than 5 s.
			shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer shutdownCancel()
			if err := c.server.Shutdown(shutdownCtx); err != nil {
				log.Printf("⚠️ HTTP server shutdown error (force-closing): %v", err)
				c.server.Close() // hard close if graceful timed out
			}
		}
		// All background goroutines are context-driven, so this normally
		// returns quickly; if something straggles, closing the DBs after a
		// bounded wait is still safe — a late write hits Badger's
		// ErrDBClosed (or the runsafe recover) instead of corrupting state.
		// In a backgrounded app the sockets are frozen, so stragglers are
		// common — the short wait matters more than a clean drain.
		if !c.waitBackground(2 * time.Second) {
			log.Println("⚠️ background goroutines did not exit within 2s; closing DBs anyway")
		}
		CloseDBs()
	})
}

//export RequestRelaySyncC
func RequestRelaySyncC() {
	// Triggers an immediate inbox + owner catch-up pull in the running relay
	// (used by the apps' pull-to-refresh). No-op-safe if the relay isn't up.
	RequestRelaySync()
}

//export TrimMemoryC
func TrimMemoryC() {
	// Called when the host app backgrounds. Sync/import rounds spike the heap,
	// and darwin's lazy reclaim (MADV_FREE) keeps that peak resident until the
	// runtime hands the pages back — otherwise only after the next import,
	// feed sync, or WoT rebuild happens to call FreeOSMemory itself, which on
	// an idle relay can be an hour away.
	//
	// This runs a full GC and returns free spans to the OS, so it is not cheap
	// (tens to hundreds of ms). Callers must invoke it off the main thread.
	debug.FreeOSMemory()
}

//export UpdateBlacklistC
func UpdateBlacklistC(npubsJSON *C.char) {
	// Called whenever the client blocks/unblocks a pubkey, on any account, so
	// it takes effect at the relay immediately instead of only on next launch
	// — see UpdateBlacklist's doc comment for why that gap mattered.
	var npubs []string
	if err := json.Unmarshal([]byte(C.GoString(npubsJSON)), &npubs); err != nil {
		log.Printf("⚠️ UpdateBlacklistC: failed to parse npubs JSON: %v", err)
		return
	}
	pubkeys := make(map[string]struct{}, len(npubs))
	for _, npub := range npubs {
		if pk := nPubToPubkey(strings.TrimSpace(npub)); pk != "" {
			pubkeys[pk] = struct{}{}
		}
	}
	UpdateBlacklist(pubkeys)
	log.Printf("🚷 Live blacklist updated: %d pubkey(s)", len(pubkeys))
}

//export BackupDatabaseC
func BackupDatabaseC(outputPath *C.char) (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 backup recovered from panic: %v", r)
			ret = 1
		}
	}()
	goPath := C.GoString(outputPath)
	log.Printf("📦 Starting database backup to %s", goPath)

	return C.int(withExclusiveDBs("backup", func() int {
		config = loadConfig()
		if err := initDBs(); err != nil {
			log.Println("🚫 backup: failed to init DBs:", err)
			return 1
		}
		defer CloseDBs()

		ctx := context.Background()
		if err := exportToZip(ctx, goPath); err != nil {
			log.Println("🚫 backup failed:", err)
			return 1
		}

		log.Println("✅ Database backup complete")
		return 0
	}))
}

//export RestoreDatabaseC
func RestoreDatabaseC(inputPath *C.char) (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 restore recovered from panic: %v", r)
			ret = 1
		}
	}()
	goPath := C.GoString(inputPath)
	log.Printf("📦 Starting database restore from %s", goPath)

	return C.int(withExclusiveDBs("restore", func() int {
		config = loadConfig()
		if err := initDBs(); err != nil {
			log.Println("🚫 restore: failed to init DBs:", err)
			return 1
		}
		defer CloseDBs()

		ctx := context.Background()
		if err := importFromZip(ctx, goPath); err != nil {
			log.Println("🚫 restore failed:", err)
			return 1
		}

		log.Println("✅ Database restore complete")
		return 0
	}))
}

//export BackupToCloudC
func BackupToCloudC() (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 cloud backup recovered from panic: %v", r)
			ret = 1
		}
	}()
	log.Println("☁️ Starting cloud backup")

	return C.int(withExclusiveDBs("cloud backup", func() int {
		config = loadConfig()
		if err := initDBs(); err != nil {
			log.Println("🚫 cloud backup: failed to init DBs:", err)
			return 1
		}
		defer CloseDBs()

		ctx := context.Background()
		zipFileName := "haven_backup.zip"

		if err := exportToZip(ctx, zipFileName); err != nil {
			log.Println("🚫 cloud backup: export failed:", err)
			return 1
		}
		defer os.Remove(zipFileName)

		cloudProvider, err := getCloudProvider()
		if err != nil {
			log.Println("🚫 cloud backup:", err)
			return 1
		}

		if err := uploadBackupToCloud(ctx, cloudProvider, zipFileName); err != nil {
			log.Println("🚫 cloud backup: upload failed:", err)
			return 1
		}

		log.Println("✅ Cloud backup complete")
		return 0
	}))
}

//export RestoreFromCloudC
func RestoreFromCloudC() (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 cloud restore recovered from panic: %v", r)
			ret = 1
		}
	}()
	log.Println("☁️ Starting cloud restore")

	return C.int(withExclusiveDBs("cloud restore", func() int {
		config = loadConfig()

		zipFileName := "haven_backup.zip"
		ctx := context.Background()

		cloudProvider, err := getCloudProvider()
		if err != nil {
			log.Println("🚫 cloud restore:", err)
			return 1
		}

		if err := downloadBackupFromCloud(ctx, cloudProvider, zipFileName); err != nil {
			log.Println("🚫 cloud restore: download failed:", err)
			return 1
		}
		defer os.Remove(zipFileName)

		if err := initDBs(); err != nil {
			log.Println("🚫 cloud restore: failed to init DBs:", err)
			return 1
		}
		defer CloseDBs()

		if err := importFromZip(ctx, zipFileName); err != nil {
			log.Println("🚫 cloud restore: import failed:", err)
			return 1
		}

		log.Println("✅ Cloud restore complete")
		return 0
	}))
}

//export ZipDirectoryC
func ZipDirectoryC(dirPath *C.char, zipPath *C.char) C.int {
	goDirPath := C.GoString(dirPath)
	goZipPath := C.GoString(zipPath)
	if err := ZipDirectory(goDirPath, goZipPath); err != nil {
		log.Printf("🚫 zip failed: %v", err)
		return 1
	}
	return 0
}

//export UnzipDirectoryC
func UnzipDirectoryC(zipPath *C.char, destPath *C.char) C.int {
	goZipPath := C.GoString(zipPath)
	goDestPath := C.GoString(destPath)
	if err := UnzipDirectory(goZipPath, goDestPath); err != nil {
		log.Printf("🚫 unzip failed: %v", err)
		return 1
	}
	return 0
}

//export SignEventC
func SignEventC(jsonStr *C.char, sk *C.char) *C.char {
	event := nostr.Event{}
	if err := easyjson.Unmarshal([]byte(C.GoString(jsonStr)), &event); err != nil {
		slog.Error("SignEventC: failed to unmarshal event", "error", err)
		return nil
	}
	if err := event.Sign(C.GoString(sk)); err != nil {
		slog.Error("SignEventC: failed to sign event", "error", err)
		return nil
	}
	res, _ := easyjson.Marshal(event)
	return C.CString(string(res))
}

// countLeadingZeroBits counts leading zero bits in a byte slice (typically a 32-byte SHA-256 hash).
func countLeadingZeroBits(data []byte) int {
	n := 0
	for _, b := range data {
		if b == 0 {
			n += 8
		} else {
			n += bits.LeadingZeros8(b)
			break
		}
	}
	return n
}

// escapeStringForMining mirrors go-nostr's unexported escapeString (NIP-01 canonical
// string escaping) so the mining fast-path below can build identical serialization
// bytes without depending on vendor internals.
func escapeStringForMining(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			dst = append(dst, '\\', '"')
		case c == '\\':
			dst = append(dst, '\\', '\\')
		case c >= 0x20:
			dst = append(dst, c)
		case c == 0x08:
			dst = append(dst, '\\', 'b')
		case c < 0x09:
			dst = append(dst, '\\', 'u', '0', '0', '0', '0'+c)
		case c == 0x09:
			dst = append(dst, '\\', 't')
		case c == 0x0a:
			dst = append(dst, '\\', 'n')
		case c == 0x0c:
			dst = append(dst, '\\', 'f')
		case c == 0x0d:
			dst = append(dst, '\\', 'r')
		case c < 0x10:
			dst = append(dst, '\\', 'u', '0', '0', '0', 0x57+c)
		case c < 0x1a:
			dst = append(dst, '\\', 'u', '0', '0', '1', 0x20+c)
		case c < 0x20:
			dst = append(dst, '\\', 'u', '0', '0', '1', 0x47+c)
		}
	}
	dst = append(dst, '"')
	return dst
}

// buildMiningPrefixSuffix precomputes the NIP-01 serialization bytes surrounding a
// nonce tag (always the last tag while mining) so each attempt only has to append
// the nonce digits between them, rather than re-serializing the whole event.
//
// A full serialization looks like:
//
//	[0,"<pubkey>",<created_at>,<kind>,[...baseTags...,["nonce","<nonce>","<diff>"]],"<content>"]
//
// prefix covers everything through the opening quote of the nonce value; suffix
// covers everything from the closing quote of the nonce value onward.
func buildMiningPrefixSuffix(pubkey string, createdAt int64, kind int, baseTags nostr.Tags, content string, diffStr string) (prefix, suffix []byte) {
	prefix = append(prefix, "[0,\""...)
	prefix = append(prefix, pubkey...)
	prefix = append(prefix, "\","...)
	prefix = strconv.AppendInt(prefix, createdAt, 10)
	prefix = append(prefix, ',')
	prefix = strconv.AppendInt(prefix, int64(kind), 10)
	prefix = append(prefix, ',', '[')
	for i, tag := range baseTags {
		if i > 0 {
			prefix = append(prefix, ',')
		}
		prefix = append(prefix, '[')
		for j, s := range tag {
			if j > 0 {
				prefix = append(prefix, ',')
			}
			prefix = escapeStringForMining(prefix, s)
		}
		prefix = append(prefix, ']')
	}
	if len(baseTags) > 0 {
		prefix = append(prefix, ',')
	}
	prefix = append(prefix, "[\"nonce\",\""...)

	suffix = append(suffix, "\",\""...)
	suffix = append(suffix, diffStr...)
	suffix = append(suffix, "\"]],"...)
	suffix = escapeStringForMining(suffix, content)
	suffix = append(suffix, ']')

	return prefix, suffix
}

//export MineAndSignEventC
func MineAndSignEventC(jsonStr *C.char, sk *C.char, difficulty C.int, maxAttempts C.int) *C.char {
	diff := int(difficulty)
	maxAtt := int(maxAttempts)

	event := nostr.Event{}
	if err := easyjson.Unmarshal([]byte(C.GoString(jsonStr)), &event); err != nil {
		slog.Error("MineAndSignEventC: failed to unmarshal event", "error", err)
		return nil
	}

	// If difficulty is 0, skip mining and just sign
	if diff <= 0 {
		if err := event.Sign(C.GoString(sk)); err != nil {
			slog.Error("MineAndSignEventC: failed to sign event", "error", err)
			return nil
		}
		res, _ := easyjson.Marshal(event)
		return C.CString(string(res))
	}

	// Default maxAttempts safety valve
	if maxAtt <= 0 {
		maxAtt = 10_000_000
	}

	diffStr := strconv.Itoa(diff)
	baseTags := make(nostr.Tags, len(event.Tags))
	copy(baseTags, event.Tags)

	// The nonce tag is always appended last, so everything around it (header,
	// existing tags, content) is identical on every attempt. Precompute that
	// once and only vary the nonce digits per attempt, instead of
	// re-serializing (and re-escaping the full content) up to maxAttempts
	// times — for longer notes that re-serialization cost dominates mining
	// time and can turn a "few second" mine into a multi-minute one.
	prefix, suffix := buildMiningPrefixSuffix(event.PubKey, int64(event.CreatedAt), event.Kind, baseTags, event.Content, diffStr)
	buf := make([]byte, 0, len(prefix)+24+len(suffix))

	for nonce := 0; nonce < maxAtt; nonce++ {
		buf = buf[:0]
		buf = append(buf, prefix...)
		buf = strconv.AppendInt(buf, int64(nonce), 10)
		buf = append(buf, suffix...)

		// Hash
		h := sha256.Sum256(buf)

		// Check leading zero bits
		if countLeadingZeroBits(h[:]) >= diff {
			// Found valid nonce — sign and return
			mineTags := make(nostr.Tags, len(baseTags), len(baseTags)+1)
			copy(mineTags, baseTags)
			mineTags = append(mineTags, nostr.Tag{"nonce", strconv.Itoa(nonce), diffStr})
			event.Tags = mineTags

			if err := event.Sign(C.GoString(sk)); err != nil {
				slog.Error("MineAndSignEventC: failed to sign mined event", "error", err)
				return nil
			}
			res, _ := easyjson.Marshal(event)
			return C.CString(string(res))
		}
	}

	// Exhausted maxAttempts — sign without PoW (graceful degradation)
	slog.Warn("MineAndSignEventC: exhausted maxAttempts, signing without PoW", "difficulty", diff, "maxAttempts", maxAtt)
	event.Tags = baseTags
	if err := event.Sign(C.GoString(sk)); err != nil {
		slog.Error("MineAndSignEventC: fallback sign failed", "error", err)
		return nil
	}
	res, _ := easyjson.Marshal(event)
	return C.CString(string(res))
}

//export GenerateKeyPairC
func GenerateKeyPairC() *C.char {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	return C.CString(fmt.Sprintf("%s:%s", sk, pk))
}

//export GetPublicKeyC
func GetPublicKeyC(sk *C.char) *C.char {
	pk, err := nostr.GetPublicKey(C.GoString(sk))
	if err != nil {
		return nil
	}
	return C.CString(pk)
}

//export EncryptNIP04C
func EncryptNIP04C(plaintext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	sharedSecret, err := nip04.ComputeSharedSecret(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("EncryptNIP04C: ComputeSharedSecret failed", "err", err)
		return nil
	}

	encrypted, err := nip04.Encrypt(C.GoString(plaintext), sharedSecret)
	if err != nil {
		slog.Error("EncryptNIP04C: Encrypt failed", "err", err)
		return nil
	}
	return C.CString(encrypted)
}

//export DeriveTaprootAddressC
func DeriveTaprootAddressC(hexPubKey *C.char) *C.char {
	addr, err := deriveP2TRAddress(C.GoString(hexPubKey))
	if err != nil {
		slog.Error("DeriveTaprootAddressC: failed", "error", err)
		return nil
	}
	return C.CString(addr)
}

//export DecryptNIP04C
func DecryptNIP04C(ciphertext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	sharedSecret, err := nip04.ComputeSharedSecret(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("DecryptNIP04C: ComputeSharedSecret failed", "err", err)
		return nil
	}

	decrypted, err := nip04.Decrypt(C.GoString(ciphertext), sharedSecret)
	if err != nil {
		slog.Error("DecryptNIP04C: Decrypt failed", "err", err)
		return nil
	}
	return C.CString(decrypted)
}

//export EncryptNIP44C
func EncryptNIP44C(plaintext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("EncryptNIP44C: GenerateConversationKey failed", "err", err)
		return nil
	}
	encrypted, err := nip44.Encrypt(C.GoString(plaintext), convKey)
	if err != nil {
		slog.Error("EncryptNIP44C: Encrypt failed", "err", err)
		return nil
	}
	return C.CString(encrypted)
}

//export DecryptNIP44C
func DecryptNIP44C(ciphertext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("DecryptNIP44C: GenerateConversationKey failed", "err", err)
		return nil
	}
	decrypted, err := nip44.Decrypt(C.GoString(ciphertext), convKey)
	if err != nil {
		slog.Error("DecryptNIP44C: Decrypt failed", "err", err)
		return nil
	}
	return C.CString(decrypted)
}

// --- NIP-49 Helpers (bech32 + scrypt + XChaCha20-Poly1305) ---

const bech32OrigConst = uint32(1) // original bech32 (not bech32m)

func bech32Checksum(hrp string, data []byte) []byte {
	values := append(bech32HRPExpand(hrp), data...)
	polymod := bech32Polymod(append(values, 0, 0, 0, 0, 0, 0)) ^ bech32OrigConst
	ret := make([]byte, 6)
	for i := range ret {
		ret[i] = byte(polymod>>(5*(5-i))) & 31
	}
	return ret
}

func encodeBech32(hrp string, payload []byte) (string, error) {
	data5 := convertBits8to5(payload)
	checksum := bech32Checksum(hrp, data5)
	combined := append(data5, checksum...)
	var sb strings.Builder
	sb.WriteString(hrp)
	sb.WriteByte('1')
	for _, b := range combined {
		sb.WriteByte(bech32Charset[b])
	}
	return sb.String(), nil
}

func convertBits5to8(data []byte) ([]byte, error) {
	acc, bits := 0, 0
	var ret []byte
	for _, v := range data {
		if v >= 32 {
			return nil, fmt.Errorf("invalid bech32 data byte: %d", v)
		}
		acc = (acc << 5) | int(v)
		bits += 5
		for bits >= 8 {
			bits -= 8
			ret = append(ret, byte((acc>>bits)&0xff))
		}
	}
	return ret, nil
}

func decodeBech32(s string) (string, []byte, error) {
	s = strings.ToLower(s)
	pos := strings.LastIndex(s, "1")
	if pos < 1 || pos+7 > len(s) {
		return "", nil, fmt.Errorf("invalid bech32 separator position")
	}
	hrp := s[:pos]
	dataStr := s[pos+1:]

	var data5 []byte
	for _, c := range dataStr {
		idx := strings.IndexByte(bech32Charset, byte(c))
		if idx < 0 {
			return "", nil, fmt.Errorf("invalid bech32 character: %c", c)
		}
		data5 = append(data5, byte(idx))
	}

	// Verify checksum
	values := append(bech32HRPExpand(hrp), data5...)
	if bech32Polymod(values) != bech32OrigConst {
		return "", nil, fmt.Errorf("bech32 checksum mismatch")
	}

	// Strip checksum (last 6 bytes)
	data5 = data5[:len(data5)-6]
	payload, err := convertBits5to8(data5)
	if err != nil {
		return "", nil, err
	}
	return hrp, payload, nil
}

//export EncryptNIP49C
func EncryptNIP49C(nsecHex *C.char, password *C.char) *C.char {
	keyBytes, err := hex.DecodeString(C.GoString(nsecHex))
	if err != nil || len(keyBytes) != 32 {
		slog.Error("EncryptNIP49C: invalid hex key", "err", err)
		return nil
	}

	pw := []byte(C.GoString(password))
	if len(pw) == 0 {
		slog.Error("EncryptNIP49C: empty password")
		return nil
	}

	// NIP-49: scrypt with N=2^16, r=8, p=1
	logN := byte(16)
	N := 1 << int(logN) // 65536

	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		slog.Error("EncryptNIP49C: rand salt failed", "err", err)
		return nil
	}

	derivedKey, err := scrypt.Key(pw, salt, N, 8, 1, 32)
	if err != nil {
		slog.Error("EncryptNIP49C: scrypt failed", "err", err)
		return nil
	}

	nonce := make([]byte, chacha20poly1305.NonceSizeX) // 24 bytes
	if _, err := rand.Read(nonce); err != nil {
		slog.Error("EncryptNIP49C: rand nonce failed", "err", err)
		return nil
	}

	aead, err := chacha20poly1305.NewX(derivedKey)
	if err != nil {
		slog.Error("EncryptNIP49C: NewX failed", "err", err)
		return nil
	}

	// Encrypt (ciphertext includes 16-byte Poly1305 tag appended)
	ciphertext := aead.Seal(nil, nonce, keyBytes, nil)

	// NIP-49 payload: version(1) + logN(1) + salt(16) + nonce(24) + encrypted(48 = 32+16)
	payload := make([]byte, 0, 1+1+16+24+len(ciphertext))
	payload = append(payload, 0x02) // NIP-49 version 2
	payload = append(payload, logN)
	payload = append(payload, salt...)
	payload = append(payload, nonce...)
	payload = append(payload, ciphertext...)

	encoded, err := encodeBech32("ncryptsec", payload)
	if err != nil {
		slog.Error("EncryptNIP49C: bech32 encode failed", "err", err)
		return nil
	}

	return C.CString(encoded)
}

//export DecryptNIP49C
func DecryptNIP49C(ncryptsec *C.char, password *C.char) *C.char {
	hrp, payload, err := decodeBech32(C.GoString(ncryptsec))
	if err != nil || hrp != "ncryptsec" {
		slog.Error("DecryptNIP49C: bech32 decode failed", "err", err, "hrp", hrp)
		return nil
	}

	pw := []byte(C.GoString(password))
	if len(pw) == 0 {
		slog.Error("DecryptNIP49C: empty password")
		return nil
	}

	// NIP-49 payload: version(1) + logN(1) + salt(16) + nonce(24) + ciphertext(48)
	if len(payload) < 1+1+16+24+32+16 {
		slog.Debug("DecryptNIP49C: payload too short (likely legacy format)", "len", len(payload))
		return nil
	}

	version := payload[0]
	if version != 0x02 {
		slog.Debug("DecryptNIP49C: unsupported version (likely legacy format)", "version", version)
		return nil
	}

	logN := payload[1]
	N := 1 << int(logN)
	salt := payload[2:18]
	nonce := payload[18:42]
	ciphertext := payload[42:]

	derivedKey, err := scrypt.Key(pw, salt, N, 8, 1, 32)
	if err != nil {
		slog.Error("DecryptNIP49C: scrypt failed", "err", err)
		return nil
	}

	aead, err := chacha20poly1305.NewX(derivedKey)
	if err != nil {
		slog.Error("DecryptNIP49C: NewX failed", "err", err)
		return nil
	}

	plaintext, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		slog.Error("DecryptNIP49C: decrypt failed", "err", err)
		return nil
	}

	return C.CString(hex.EncodeToString(plaintext))
}

//export FetchFeeEstimatesC
func FetchFeeEstimatesC() *C.char {
	fees, err := fetchFeeEstimates()
	if err != nil {
		result, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(result))
	}
	result, _ := json.Marshal(fees)
	return C.CString(string(result))
}

// SweepToAddressC sweeps all UTXOs from the Nostr-derived taproot address to
// destAddr. feeRateSatsPerVB is the desired fee rate (sat/vB).
// Returns JSON: {"txid":"…","amount":…,"fee":…} or {"error":"…"}.
//
//export SweepToAddressC
func SweepToAddressC(nsecHex *C.char, destAddr *C.char, feeRateSatsPerVB C.int) *C.char {
	result, err := buildAndBroadcastSweep(
		C.GoString(nsecHex),
		C.GoString(destAddr),
		int64(feeRateSatsPerVB),
	)
	if err != nil {
		out, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(out))
	}
	out, _ := json.Marshal(result)
	return C.CString(string(out))
}

// ---------------------------------------------------------------------------
// NIP-46 Remote Signer Bridge
// ---------------------------------------------------------------------------

//export NIP46ConnectC
func NIP46ConnectC(clientSK *C.char, bunkerURL *C.char) *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("NIP46ConnectC: recovered from panic: %v", r)
		}
	}()

	goSK := C.GoString(clientSK)
	goURL := C.GoString(bunkerURL)

	nip46Mu.Lock()
	defer nip46Mu.Unlock()

	// Tear down any prior session
	if nip46Cancel != nil {
		nip46Cancel()
	}
	nip46Client = nil

	nip46Ctx, nip46Cancel = context.WithCancel(context.Background())
	nip46Pool = nostr.NewSimplePool(nip46Ctx)

	nip46PendingAuthURL.Store("")

	onAuth := func(authURL string) {
		log.Printf("NIP-46: auth challenge: %s", authURL)
		nip46PendingAuthURL.Store(authURL)
	}

	// Parse the bunker URL to extract relay(s), target pubkey, and secret.
	parsed, err := url.Parse(goURL)
	if err != nil {
		slog.Error("NIP46ConnectC: invalid bunker URL", "error", err)
		nip46Cancel()
		return nil
	}
	targetPubkey := parsed.Host
	relays := parsed.Query()["relay"]
	secret := parsed.Query().Get("secret")

	if !nostr.IsValidPublicKey(targetPubkey) {
		slog.Error("NIP46ConnectC: invalid target pubkey", "pubkey", targetPubkey)
		nip46Cancel()
		return nil
	}
	if len(relays) == 0 {
		slog.Error("NIP46ConnectC: no relay in bunker URL")
		nip46Cancel()
		return nil
	}

	// Create the bunker client with the long-lived nip46Ctx so the background
	// subscription that listens for RPC responses stays alive for the entire
	// session.  Previously we passed a 30-second timeout context to
	// ConnectBunker which also fed into NewBunker → pool.SubscribeMany; when
	// the timeout fired (or defer-cancel ran), the subscription died and all
	// subsequent RPCs (sign_event, encrypt, etc.) would never receive a reply.
	bunker := nip46.NewBunker(nip46Ctx, goSK, targetPubkey, relays, nip46Pool, onAuth)

	// The connect RPC itself gets a timeout so we don't block forever when
	// the signer is offline.
	log.Printf("NIP46ConnectC: sending connect RPC to %s via %v (secret=%d chars)", targetPubkey[:8], relays, len(secret))
	connectCtx, connectCancel := context.WithTimeout(nip46Ctx, 60*time.Second)
	defer connectCancel()

	if _, err := bunker.RPC(connectCtx, "connect", []string{targetPubkey, secret}); err != nil {
		slog.Error("NIP46ConnectC: connect RPC failed", "error", err)
		nip46Cancel()
		nip46Client = nil
		nip46Pool = nil
		return nil
	}

	log.Printf("NIP46ConnectC: connect RPC succeeded, requesting public key...")
	nip46Client = bunker

	// GetPublicKey also gets a timeout to prevent hanging indefinitely
	pkCtx, pkCancel := context.WithTimeout(nip46Ctx, 30*time.Second)
	defer pkCancel()

	pubkey, err := bunker.GetPublicKey(pkCtx)
	if err != nil {
		slog.Error("NIP46ConnectC: GetPublicKey failed", "error", err)
		return nil
	}

	log.Printf("NIP-46: connected to signer %s", pubkey[:8])
	return C.CString(pubkey)
}

//export NIP46DisconnectC
func NIP46DisconnectC() {
	nip46Mu.Lock()
	defer nip46Mu.Unlock()

	if nip46Cancel != nil {
		nip46Cancel()
	}
	nip46Client = nil
	nip46Pool = nil
	nip46PendingAuthURL.Store("")
	log.Println("NIP-46: disconnected")
}

//export NIP46SignEventC
func NIP46SignEventC(eventJSON *C.char) *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46SignEventC: not connected")
		return nil
	}

	var event nostr.Event
	if err := easyjson.Unmarshal([]byte(C.GoString(eventJSON)), &event); err != nil {
		slog.Error("NIP46SignEventC: unmarshal failed", "error", err)
		return nil
	}

	pubPrefix := event.PubKey
	if len(pubPrefix) > 8 {
		pubPrefix = pubPrefix[:8]
	}
	log.Printf("NIP46SignEventC: sending sign_event to bunker kind=%d pubkey=%s tags=%v", event.Kind, pubPrefix, event.Tags)

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	if err := client.SignEvent(ctx, &event); err != nil {
		slog.Error("NIP46SignEventC: SignEvent failed", "kind", event.Kind, "error", err)
		return nil
	}

	res, _ := easyjson.Marshal(event)
	log.Printf("NIP46SignEventC: signed ok – id=%s kind=%d pubkey=%s", event.ID[:8], event.Kind, event.PubKey[:8])
	return C.CString(string(res))
}

//export NIP46GetPublicKeyC
func NIP46GetPublicKeyC() *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46GetPublicKeyC: not connected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	pubkey, err := client.GetPublicKey(ctx)
	if err != nil {
		slog.Error("NIP46GetPublicKeyC: failed", "error", err)
		return nil
	}
	return C.CString(pubkey)
}

//export NIP46NIP44EncryptC
func NIP46NIP44EncryptC(targetPubkey *C.char, plaintext *C.char) *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46NIP44EncryptC: not connected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP44Encrypt(ctx, C.GoString(targetPubkey), C.GoString(plaintext))
	if err != nil {
		slog.Error("NIP46NIP44EncryptC: failed", "error", err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP44DecryptC
func NIP46NIP44DecryptC(targetPubkey *C.char, ciphertext *C.char) *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46NIP44DecryptC: not connected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP44Decrypt(ctx, C.GoString(targetPubkey), C.GoString(ciphertext))
	if err != nil {
		slog.Error("NIP46NIP44DecryptC: failed", "error", err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP04EncryptC
func NIP46NIP04EncryptC(targetPubkey *C.char, plaintext *C.char) *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46NIP04EncryptC: not connected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP04Encrypt(ctx, C.GoString(targetPubkey), C.GoString(plaintext))
	if err != nil {
		slog.Error("NIP46NIP04EncryptC: failed", "error", err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP04DecryptC
func NIP46NIP04DecryptC(targetPubkey *C.char, ciphertext *C.char) *C.char {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		slog.Error("NIP46NIP04DecryptC: not connected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP04Decrypt(ctx, C.GoString(targetPubkey), C.GoString(ciphertext))
	if err != nil {
		slog.Error("NIP46NIP04DecryptC: failed", "error", err)
		return nil
	}
	return C.CString(result)
}

//export NIP46PingC
func NIP46PingC() C.int {
	nip46Mu.RLock()
	client := nip46Client
	parentCtx := nip46Ctx
	nip46Mu.RUnlock()

	if client == nil {
		return 1
	}

	ctx, cancel := context.WithTimeout(parentCtx, 15*time.Second)
	defer cancel()

	if err := client.Ping(ctx); err != nil {
		slog.Error("NIP46PingC: failed", "error", err)
		return 1
	}
	return 0
}

//export NIP46GetPendingAuthURLC
func NIP46GetPendingAuthURLC() *C.char {
	val := nip46PendingAuthURL.Load()
	if val == nil {
		return nil
	}
	url, ok := val.(string)
	if !ok || url == "" {
		return nil
	}
	// Consume on read
	nip46PendingAuthURL.Store("")
	return C.CString(url)
}

// ---------------------------------------------------------------------------
// Local DVM: Popular Notes
// ---------------------------------------------------------------------------

//export ComputePopularNotesC
func ComputePopularNotesC() *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("ComputePopularNotesC: recovered from panic: %v", r)
		}
	}()

	// Snapshot the live cycle so a concurrent stop can't yank the pool or
	// context out from under us mid-computation.
	c := relayLC.current.Load()
	if c == nil || c.server == nil { // server == nil means import cycle
		result, _ := json.Marshal(map[string]string{"error": "relay not running"})
		return C.CString(string(result))
	}

	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
	defer cancel()

	notes, err := computePopularNotes(ctx)
	if err != nil {
		result, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(result))
	}

	result, err := json.Marshal(notes)
	if err != nil {
		result, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(result))
	}
	return C.CString(string(result))
}

// Dummy main() function required for buildmode=c-archive
// This is never called; entry points are the exported C functions above
func main() {
}
