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
	"slices"
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

// NIP-46 remote signer state (independent of relay lifecycle).
//
// One live session per signer, so switching between accounts that each sign
// with their own bunker is instant: the session for the account switched to
// is still connected, and nothing has to log in again. Only one session is
// active (the one requests go to); the others stay connected in the
// background. nip46Mu guards the map and the active key only; it is never
// held across a network round trip, so a slow login cannot block signing
// on another session or freeze the caller.
type nip46Session struct {
	ctx    context.Context
	cancel context.CancelFunc
	pool   *nostr.SimplePool
	client *nip46.BunkerClient
	userPubkey string
	// What signReplyRecovery needs to read the signer's replies itself.
	signer   string
	relays   []string
	clientSK string
}

var (
	nip46Sessions = map[string]*nip46Session{} // keyed by signer (bunker) pubkey
	nip46Active   string
	// Bumped on every activation, so a login that finishes after the user
	// moved to another account is kept but does not take over.
	nip46ActiveGen uint64
	nip46Mu        sync.RWMutex

	nip46PendingAuthURL atomic.Value // stores string

	// nip46LastError records why the most recent NIP-46 call returned nil, so
	// the app can tell "the signer said no" from "the signer never answered".
	// One of "timeout", "offline", "rejected:<signer message>", "error:<detail>".
	nip46LastError atomic.Value // stores string
)

// nip46Perms is what the app asks a signer for at connect time.
const nip46Perms = "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt"

// nip46ClientMetadata rides as the optional 4th connect param so a signer
// (Clave shows it as the connection's name) knows which app is asking. It is
// a JSON string, not an object: signers decode params as string[].
const nip46ClientMetadata = `{"name":"Nostr Vault","url":"https://nostrvault.app","image":"https://nostrvault.app/assets/haven_icon.png"}`

// recordNIP46Error stores why a NIP-46 call failed, for NIP46LastErrorC.
func recordNIP46Error(ctx context.Context, err error) {
	nip46LastError.Store(classifyNIP46Error(ctx, err))
}

// NIP46LastErrorC returns the classification of the most recent failed
// NIP-46 call (see nip46LastError), or "" if none.
//
//export NIP46LastErrorC
func NIP46LastErrorC() *C.char {
	val, _ := nip46LastError.Load().(string)
	return C.CString(val)
}

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
			)

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
			cycle.spawn("followerLedger", func() { runFollowerLedger(cycle.ctx) })
			cycle.spawn("syncFeed", func() { syncFeed(cycle.ctx) })
			cycle.spawn("ingestPopularEngagement", func() { ingestPopularEngagement(cycle.ctx) })
			cycle.spawn("periodicCloudBackups", func() { startPeriodicCloudBackups(cycle.ctx) })
			cycle.spawn("wot.PeriodicRefresh", func() { wot.PeriodicRefresh(cycle.ctx, config.WotRefreshInterval) })
			cycle.spawn("wot.RefreshWhileEmpty", func() { wot.RefreshWhileEmpty(cycle.ctx, wot.EmptyGraphRefreshInterval) })
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

		// iOS serves TLS for App Transport Security, but the FIPS mesh tunnel
		// carries plain HTTP: give it the same handler on a loopback-only port.
		if port, err := strconv.Atoi(os.Getenv("HAVEN_MESH_PLAIN_PORT")); err == nil && port > 0 && certPath != "" {
			meshAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
			cycle.meshServer = &http.Server{Addr: meshAddr, Handler: mux}
			cycle.spawn("mesh-http-server", func() {
				if err := cycle.meshServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
					log.Printf("🚫 mesh HTTP server exited: %v", err)
				}
			})
			log.Printf("🔗 mesh listening at http://%s", meshAddr)
		}

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
		if c.meshServer != nil {
			// Its handlers are the same ones server just drained; close outright.
			c.meshServer.Close()
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

//export RefreshWotC
func RefreshWotC() C.int {
	// Rebuilds the web of trust now (the WOT tab's refresh button) instead of
	// at the next daily refresh. 1 when a rebuild started or was already
	// running; 0 when the relay isn't up or trust is off. Poll
	// WotRefreshProgressC for how far it has got.
	defer func() {
		if r := recover(); r != nil {
			log.Printf("RefreshWotC: recovered from panic: %v", r)
		}
	}()
	c := relayLC.current.Load()
	if c == nil || c.server == nil { // server == nil means import cycle
		return 0
	}
	if wot.RefreshNow(c.ctx, wot.GetInstance(), c.spawn) {
		return 1
	}
	return 0
}

//export WotRefreshProgressC
func WotRefreshProgressC() *C.char {
	// JSON of wot.Progress. The caller frees the string.
	result, _ := json.Marshal(wot.CurrentProgress())
	return C.CString(string(result))
}

//export RequestCatchUpC
func RequestCatchUpC() {
	// Like RequestRelaySyncC, but for the app returning from absence
	// (foreground, background wake): the round may post a "while you were
	// away" summary. No-op-safe if the relay isn't up.
	RequestCatchUp()
}

//export RequestMacSyncCheckC
func RequestMacSyncCheckC() {
	// Re-runs the Mac relay full-history copy and its missing-events check;
	// the result lands in mac_sync_status.json. No-op without a Mac relay.
	RequestMacSyncCheck()
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
		if pk := nPubToPubkey("blacklist", strings.TrimSpace(npub)); pk != "" {
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

// VerifyEventC returns 1 when the event JSON's id is the NIP-01 hash of its
// contents and its sig is a valid schnorr signature by its pubkey, else 0.
//
//export VerifyEventC
func VerifyEventC(jsonStr *C.char) C.int {
	event := nostr.Event{}
	if err := easyjson.Unmarshal([]byte(C.GoString(jsonStr)), &event); err != nil {
		return 0
	}
	if !event.CheckID() {
		return 0
	}
	if ok, err := event.CheckSignature(); err != nil || !ok {
		return 0
	}
	return 1
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

	nip46PendingAuthURL.Store("")
	nip46LastError.Store("")

	onAuth := func(authURL string) {
		log.Printf("NIP-46: auth challenge: %s", authURL)
		nip46PendingAuthURL.Store(authURL)
	}

	// Parse the bunker URL to extract relay(s), target pubkey, and secret.
	parsed, err := url.Parse(goURL)
	if err != nil {
		slog.Error("NIP46ConnectC: invalid bunker URL", "error", err)
		nip46LastError.Store("error:invalid bunker link")
		return nil
	}
	targetPubkey := parsed.Host
	relays := parsed.Query()["relay"]
	secret := parsed.Query().Get("secret")

	if !nostr.IsValidPublicKey(targetPubkey) {
		slog.Error("NIP46ConnectC: invalid target pubkey", "pubkey", targetPubkey)
		nip46LastError.Store("error:invalid signer key in bunker link")
		return nil
	}
	if len(relays) == 0 {
		slog.Error("NIP46ConnectC: no relay in bunker URL")
		nip46LastError.Store("error:no relay in bunker link")
		return nil
	}

	// Claim the active slot for this signer and drop any previous session for
	// it (this is a fresh login, e.g. after a dead socket). Other signers'
	// sessions are left alone.
	nip46Mu.Lock()
	if old := nip46Sessions[targetPubkey]; old != nil {
		old.cancel()
		delete(nip46Sessions, targetPubkey)
	}
	nip46Active = targetPubkey
	nip46ActiveGen++
	myGen := nip46ActiveGen
	nip46Mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	pool := nostr.NewSimplePool(ctx)

	// Create the bunker client with the long-lived session ctx so the background
	// subscription that listens for RPC responses stays alive for the entire
	// session. Previously we passed a 30-second timeout context to
	// ConnectBunker which also fed into NewBunker → pool.SubscribeMany; when
	// the timeout fired (or defer-cancel ran), the subscription died and all
	// subsequent RPCs (sign_event, encrypt, etc.) would never receive a reply.
	bunker := nip46.NewBunker(ctx, goSK, targetPubkey, relays, pool, onAuth)

	// The connect RPC itself gets a timeout so we don't block forever when
	// the signer is offline. No lock is held while waiting.
	log.Printf("NIP46ConnectC: sending connect RPC to %s via %v (secret=%d chars)", targetPubkey[:8], relays, len(secret))
	connectCtx, connectCancel := context.WithTimeout(ctx, 60*time.Second)
	defer connectCancel()

	result, err := bunker.RPC(connectCtx, "connect", []string{targetPubkey, secret, nip46Perms, nip46ClientMetadata})
	if err != nil {
		slog.Error("NIP46ConnectC: connect RPC failed", "error", err)
		recordNIP46Error(connectCtx, err)
		cancel()
		return nil
	}
	// NIP-46: connect answers "ack" or echoes the secret. With a secret in
	// play, anything else did not come from the signer we paired with.
	if !nip46ConnectConfirmed(result, secret) {
		slog.Warn("NIP46ConnectC: connect result is neither ack nor our secret; accepting (response is signer-encrypted)")
	}

	log.Printf("NIP46ConnectC: connect RPC succeeded, requesting public key...")

	// GetPublicKey also gets a timeout to prevent hanging indefinitely
	pkCtx, pkCancel := context.WithTimeout(ctx, 30*time.Second)
	defer pkCancel()

	pubkey, err := bunker.GetPublicKey(pkCtx)
	if err != nil {
		slog.Error("NIP46ConnectC: GetPublicKey failed", "error", err)
		recordNIP46Error(pkCtx, err)
		cancel()
		return nil
	}

	nip46Mu.Lock()
	if old := nip46Sessions[targetPubkey]; old != nil {
		old.cancel() // a second login for the same signer finished first
	}
	nip46Sessions[targetPubkey] = &nip46Session{ctx: ctx, cancel: cancel, pool: pool, client: bunker, userPubkey: pubkey,
		signer: targetPubkey, relays: relays, clientSK: goSK}
	stillActive := nip46ActiveGen == myGen
	nip46Mu.Unlock()

	if stillActive {
		log.Printf("NIP-46: connected to signer %s", pubkey[:8])
	} else {
		log.Printf("NIP-46: connected to signer %s, kept in the background (another account became active)", pubkey[:8])
	}
	return C.CString(pubkey)
}

// activeNIP46Session returns the session requests should go to, or nil.
func activeNIP46Session() *nip46Session {
	nip46Mu.RLock()
	defer nip46Mu.RUnlock()
	return nip46Sessions[nip46Active]
}

// activeNIP46 returns the session requests should go to, or nils.
func activeNIP46() (*nip46.BunkerClient, context.Context) {
	nip46Mu.RLock()
	defer nip46Mu.RUnlock()
	if s := nip46Sessions[nip46Active]; s != nil {
		return s.client, s.ctx
	}
	return nil, context.Background()
}

// NIP46ActivateC makes an existing session for `signerPubkey` the active one
// and returns its user pubkey, or nil when there is no live session for it
// (the caller then logs in with NIP46ConnectC).
//
//export NIP46ActivateC
func NIP46ActivateC(signerPubkey *C.char) *C.char {
	target := C.GoString(signerPubkey)
	nip46Mu.Lock()
	defer nip46Mu.Unlock()
	s := nip46Sessions[target]
	if s == nil || s.ctx.Err() != nil {
		delete(nip46Sessions, target)
		return nil
	}
	nip46Active = target
	nip46ActiveGen++
	nip46PendingAuthURL.Store("")
	return C.CString(s.userPubkey)
}

// NIP46DropC closes the session for one signer (one that answered for the
// wrong account, or one that stopped answering).
//
//export NIP46DropC
func NIP46DropC(signerPubkey *C.char) {
	target := C.GoString(signerPubkey)
	nip46Mu.Lock()
	defer nip46Mu.Unlock()
	if s := nip46Sessions[target]; s != nil {
		s.cancel()
		delete(nip46Sessions, target)
	}
	if nip46Active == target {
		nip46Active = ""
	}
}

// NIP46DisconnectC closes the ACTIVE session only. Sessions of other accounts
// stay connected so switching back to them is instant.
//
//export NIP46DisconnectC
func NIP46DisconnectC() {
	nip46Mu.Lock()
	defer nip46Mu.Unlock()

	if s := nip46Sessions[nip46Active]; s != nil {
		s.cancel()
		delete(nip46Sessions, nip46Active)
	}
	nip46Active = ""
	nip46PendingAuthURL.Store("")
	log.Println("NIP-46: disconnected")
}

//export NIP46SignEventC
func NIP46SignEventC(eventJSON *C.char) *C.char {
	return nip46Sign(activeNIP46Session(), eventJSON)
}

// NIP46SignEventWithC signs through one signer's session even when it is not
// the active one (the owner's relay AUTH while browsing another account).
// Never logs in: no live session for that signer means nil, not a new
// request piling onto a signer.
//
//export NIP46SignEventWithC
func NIP46SignEventWithC(signerPubkey *C.char, eventJSON *C.char) *C.char {
	target := C.GoString(signerPubkey)
	nip46Mu.RLock()
	sess := nip46Sessions[target]
	nip46Mu.RUnlock()
	if sess == nil || sess.ctx.Err() != nil {
		nip46LastError.Store("disconnected")
		return nil
	}
	return nip46Sign(sess, eventJSON)
}

func nip46Sign(sess *nip46Session, eventJSON *C.char) *C.char {
	nip46LastError.Store("")
	if sess == nil || sess.client == nil {
		slog.Error("NIP46SignEventC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	var event nostr.Event
	if err := easyjson.Unmarshal([]byte(C.GoString(eventJSON)), &event); err != nil {
		slog.Error("NIP46SignEventC: unmarshal failed", "error", err)
		nip46LastError.Store("error:" + err.Error())
		return nil
	}

	pubPrefix := event.PubKey
	if len(pubPrefix) > 8 {
		pubPrefix = pubPrefix[:8]
	}
	log.Printf("NIP46SignEventC: sending sign_event to bunker kind=%d pubkey=%s tags=%v", event.Kind, pubPrefix, event.Tags)

	// A signer may put this in front of a person (Clave's lock-screen
	// Approve), so give them time to read it.
	ctx, cancel := context.WithTimeout(sess.ctx, 90*time.Second)
	defer cancel()

	req := event
	req.Tags = slices.Clone(event.Tags)
	if err := signWithRecovery(ctx, signerReplies{
		client: sess.client, pool: sess.pool, signer: sess.signer, relays: sess.relays, clientSK: sess.clientSK,
	}, &event); err != nil {
		slog.Error("NIP46SignEventC: SignEvent failed", "kind", event.Kind, "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	if err := checkRemoteSigned(req, event, req.PubKey); err != nil {
		slog.Error("NIP46SignEventC: rejected signer response", "kind", event.Kind, "error", err)
		nip46LastError.Store("error:" + err.Error())
		return nil
	}

	res, _ := easyjson.Marshal(event)
	log.Printf("NIP46SignEventC: signed ok – id=%s kind=%d pubkey=%s", event.ID[:8], event.Kind, event.PubKey[:8])
	return C.CString(string(res))
}

//export NIP46GetPublicKeyC
func NIP46GetPublicKeyC() *C.char {
	client, parentCtx := activeNIP46()

	nip46LastError.Store("")
	if client == nil {
		slog.Error("NIP46GetPublicKeyC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	pubkey, err := client.GetPublicKey(ctx)
	if err != nil {
		slog.Error("NIP46GetPublicKeyC: failed", "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	return C.CString(pubkey)
}

//export NIP46NIP44EncryptC
func NIP46NIP44EncryptC(targetPubkey *C.char, plaintext *C.char) *C.char {
	client, parentCtx := activeNIP46()

	nip46LastError.Store("")
	if client == nil {
		slog.Error("NIP46NIP44EncryptC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 60*time.Second)
	defer cancel()

	result, err := client.NIP44Encrypt(ctx, C.GoString(targetPubkey), C.GoString(plaintext))
	if err != nil {
		slog.Error("NIP46NIP44EncryptC: failed", "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP44DecryptC
func NIP46NIP44DecryptC(targetPubkey *C.char, ciphertext *C.char) *C.char {
	client, parentCtx := activeNIP46()

	nip46LastError.Store("")
	if client == nil {
		slog.Error("NIP46NIP44DecryptC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP44Decrypt(ctx, C.GoString(targetPubkey), C.GoString(ciphertext))
	if err != nil {
		slog.Error("NIP46NIP44DecryptC: failed", "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP04EncryptC
func NIP46NIP04EncryptC(targetPubkey *C.char, plaintext *C.char) *C.char {
	client, parentCtx := activeNIP46()

	nip46LastError.Store("")
	if client == nil {
		slog.Error("NIP46NIP04EncryptC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 60*time.Second)
	defer cancel()

	result, err := client.NIP04Encrypt(ctx, C.GoString(targetPubkey), C.GoString(plaintext))
	if err != nil {
		slog.Error("NIP46NIP04EncryptC: failed", "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	return C.CString(result)
}

//export NIP46NIP04DecryptC
func NIP46NIP04DecryptC(targetPubkey *C.char, ciphertext *C.char) *C.char {
	client, parentCtx := activeNIP46()

	nip46LastError.Store("")
	if client == nil {
		slog.Error("NIP46NIP04DecryptC: not connected")
		nip46LastError.Store("disconnected")
		return nil
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	result, err := client.NIP04Decrypt(ctx, C.GoString(targetPubkey), C.GoString(ciphertext))
	if err != nil {
		slog.Error("NIP46NIP04DecryptC: failed", "error", err)
		recordNIP46Error(ctx, err)
		return nil
	}
	return C.CString(result)
}

//export NIP46PingC
func NIP46PingC() C.int {
	client, parentCtx := activeNIP46()

	if client == nil {
		return 1
	}

	ctx, cancel := context.WithTimeout(parentCtx, 15*time.Second)
	defer cancel()

	if err := client.Ping(ctx); err != nil {
		// A keepalive the signer did not answer (its app is asleep, its
		// relay dropped us) is routine and the caller keeps the session, so
		// it is a WARN, not an ERROR. It is also not recorded in
		// nip46LastError: that slot explains the last failed *request*, and a
		// background ping must not overwrite it.
		kind := classifyNIP46Error(ctx, err)
		slog.Log(ctx, nip46PingLogLevel(kind), "NIP46PingC: signer did not answer the keepalive", "kind", kind, "error", err)
		return 1
	}
	return 0
}

// NIP46AwaitNostrConnectC listens for a signer's answer to a nostrconnect://
// pairing request (see nostrConnectAck) and returns the signer's hex pubkey,
// or nil if none arrived within waitSeconds.
//
// since is when the request was shown. Asking from then on — rather than
// "new events only" — lets a relay that keeps kind 24133 (Clave's
// relay.powr.build does) replay an answer sent while this app was suspended
// in the background, which is exactly when the user is approving in Clave.
// The app calls this in short rounds so it can stop between them.
//
//export NIP46AwaitNostrConnectC
func NIP46AwaitNostrConnectC(clientSK *C.char, relaysJSON *C.char, secret *C.char, since C.longlong, waitSeconds C.int) *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("NIP46AwaitNostrConnectC: recovered from panic: %v", r)
		}
	}()

	sk := C.GoString(clientSK)
	sec := C.GoString(secret)
	var relays []string
	if err := json.Unmarshal([]byte(C.GoString(relaysJSON)), &relays); err != nil || len(relays) == 0 {
		nip46LastError.Store("error:no relays for nostrconnect")
		return nil
	}
	clientPK, err := nostr.GetPublicKey(sk)
	if err != nil {
		nip46LastError.Store("error:invalid client key")
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(waitSeconds)*time.Second)
	defer cancel()
	pool := nostr.NewSimplePool(ctx)
	from := nostr.Timestamp(since)
	events := pool.SubscribeMany(ctx, relays, nostr.Filter{
		Kinds: []int{nostr.KindNostrConnect},
		Tags:  nostr.TagMap{"p": []string{clientPK}},
		Since: &from,
	})
	for ie := range events {
		if pk, ok := nostrConnectAck(ie.Event, sk, clientPK, sec); ok {
			log.Printf("NIP-46: nostrconnect answered by %s", pk[:8])
			return C.CString(pk)
		}
	}
	nip46LastError.Store("timeout")
	return nil
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

// ---------------------------------------------------------------------------
// Follower ledger
// ---------------------------------------------------------------------------

// GetFollowersC returns the follower ledger for owner (hex pubkey) as JSON:
// a followers.Snapshot (counts per trust tier + one entry per follower,
// newest follow first), or {"error": ...} when the relay isn't running.
//
//export GetFollowersC
func GetFollowersC(owner *C.char) *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("GetFollowersC: recovered from panic: %v", r)
		}
	}()
	c := relayLC.current.Load()
	if c == nil || c.server == nil {
		result, _ := json.Marshal(map[string]string{"error": "relay not running"})
		return C.CString(string(result))
	}
	snap, ok := followersSnapshot(c.ctx, C.GoString(owner))
	if !ok {
		result, _ := json.Marshal(map[string]string{"error": "follower ledger unavailable"})
		return C.CString(string(result))
	}
	result, err := json.Marshal(snap)
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
