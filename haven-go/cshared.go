//go:build cshared

package main

import "C"

import (
	"C"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/bitvora/haven/pkg/wot"
	"github.com/mailru/easyjson"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
	"github.com/spf13/afero"
)

var (
	csharedCtx    context.Context
	csharedCancel context.CancelFunc
	globalServer  *http.Server
)

func isCShared() bool {
	return true
}

//export SetHavenEnvC
func SetHavenEnvC(key *C.char, value *C.char) {
	os.Setenv(C.GoString(key), C.GoString(value))
}

//export StartRelayC
func StartRelayC(importMode bool) {
	// Recover from any panic so we don't crash the host app
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 HAVEN recovered from panic: %v", r)
		}
	}()

	config = loadConfig() // reload config dynamically

	nostr.InfoLogger = log.New(io.Discard, "", 0)
	slog.SetLogLoggerLevel(getLogLevelFromConfig())

	csharedCtx, csharedCancel = context.WithCancel(context.Background())

	fs = afero.NewOsFs()
	if err := fs.MkdirAll(config.BlossomPath, 0755); err != nil {
		log.Println("🚫 error creating blossom path:", err)
		return
	}

	pool = nostr.NewSimplePool(csharedCtx,
		nostr.WithPenaltyBox(),
		nostr.WithRelayOptions(
			nostr.WithRequestHeader{
				"User-Agent": []string{config.UserAgent},
			}),
	)

	log.Println("🚀 HAVEN", config.RelayVersion, "is booting up (C-Shared Mode) [1/3]")

	if importMode {
		defer CloseDBs()
		if !ensureImportRelays() {
			log.Println("🚫 Import aborted: could not connect to any seed relays")
			return
		}
		runImport(csharedCtx)
		log.Println("✅ Import completed in C-Shared mode")
		return
	}

	log.Println("⏳ Loading databases [2/3]")
	if err := initRelays(csharedCtx); err != nil {
		log.Println("🚫 error initializing databases/relays:", err)
		return
	}
	log.Println("✅ Databases ready")

	log.Println("⏳ Starting background services [3/3]")
	go func() {
		// Initialize WOT (can take time, so run in background)
		log.Println("  → Initializing Web of Trust")
		wotModel := wot.NewSimpleInMemory(
			pool,
			config.WhitelistedPubKeys,
			config.ImportSeedRelays,
			config.WotDepth,
			config.WotMinimumFollowers,
			config.WotFetchTimeoutSeconds,
			config.WotCachePath,
			config.WotCacheTTLMinutes,
		)

		// Try to load from cache first - instant startup
		// Initialize asynchronously to avoid blocking relay startup
		wotModel.LoadFromCache()
		wot.ResetReady()
		go wot.Initialize(csharedCtx, wotModel)
		log.Println("  ✓ Web of Trust initializing")

		go subscribeInboxAndChat(csharedCtx)
		go startPeriodicCloudBackups(csharedCtx)
		go wot.PeriodicRefresh(csharedCtx, config.WotRefreshInterval)
	}()

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

	addr := fmt.Sprintf("%s:%d", config.RelayBindAddress, config.RelayPort)
	globalServer = &http.Server{Addr: addr, Handler: mux}

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
	serverReady := make(chan error, 1)
	go func() {
		if certPath != "" && keyPath != "" {
			serverReady <- globalServer.ListenAndServeTLS(certPath, keyPath)
		} else {
			serverReady <- globalServer.ListenAndServe()
		}
	}()

	// Brief delay to ensure server binds to port before returning
	time.Sleep(100 * time.Millisecond)

	protocol := "http"
	if certPath != "" {
		protocol = "https"
	}
	log.Printf("🔗 listening at %s://%s", protocol, addr)
}

//export StopRelayC
func StopRelayC() {
	log.Println("🔌 HAVEN is shutting down (C-Shared Mode)")
	if csharedCancel != nil {
		csharedCancel()
	}
	if globalServer != nil {
		globalServer.Shutdown(context.Background())
		globalServer = nil
	}
	CloseDBs()
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

//export SweepToAddressC
// SweepToAddressC sweeps all UTXOs from the Nostr-derived taproot address to
// destAddr. feeRateSatsPerVB is the desired fee rate (sat/vB).
// Returns JSON: {"txid":"…","amount":…,"fee":…} or {"error":"…"}.
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

// Dummy main() function required for buildmode=c-archive
// This is never called; entry points are the exported C functions above
func main() {
}
