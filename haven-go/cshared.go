//go:build cshared

package main

import "C"

import (
	"C"
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strings"
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
		// Always initialize asynchronously to avoid blocking relay startup
		wotModel.LoadFromCache()  // Load if available, otherwise starts empty
		go wot.Initialize(csharedCtx, wotModel)
		log.Println("  ✓ Web of Trust ready")

		go subscribeInboxAndChat(csharedCtx)
		go startPeriodicCloudBackups(csharedCtx)
		go wot.PeriodicRefresh(csharedCtx, config.WotRefreshInterval)
	}()

	// Use a fresh ServeMux each cycle so stop/start never panics on
	// duplicate pattern registration in the default mux.
	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("templates/static"))))

	// Blossom + relay router - check method and route accordingly
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Blossom media endpoints (PUT, GET, DELETE on root paths)
		path := r.URL.Path
		isWebSocket := r.Header.Get("Sec-WebSocket-Key") != ""

		if path != "" && path != "/" && !isWebSocket {
			// Not a WebSocket request, check if it's Blossom
			switch r.Method {
			case "PUT":
				handleBlossomUpload(w, r)
				return
			case "GET":
				handleBlossomDownload(w, r)
				return
			case "DELETE":
				handleBlossomDelete(w, r)
				return
			}
		}
		// Fall through to relay handler
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
func BackupDatabaseC(outputPath *C.char) C.int {
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
func RestoreDatabaseC(inputPath *C.char) C.int {
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
func BackupToCloudC() C.int {
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
func RestoreFromCloudC() C.int {
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

// Blossom media handlers (iOS only)

func handleBlossomUpload(w http.ResponseWriter, r *http.Request) {
	// Extract SHA256 from path (e.g., /013725e4cfa79cdc4a7e108c3799b739d72b86eadf23586cf5e103b04ae3257f)
	sha256 := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, "/"), "")
	if sha256 == "" || len(sha256) != 64 {
		http.Error(w, "Invalid SHA256 hash", http.StatusBadRequest)
		return
	}

	// Verify NIP-98 auth header
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, "Missing Authorization header", http.StatusUnauthorized)
		return
	}

	// Read body and store
	defer r.Body.Close()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}

	// Store to filesystem
	file, err := fs.Create(config.BlossomPath + sha256)
	if err != nil {
		slog.Error("Failed to create blob file", "sha256", sha256, "error", err)
		http.Error(w, "Failed to store blob", http.StatusInternalServerError)
		return
	}
	if _, err := io.Copy(file, bytes.NewReader(body)); err != nil {
		file.Close()
		slog.Error("Failed to write blob file", "sha256", sha256, "error", err)
		http.Error(w, "Failed to store blob", http.StatusInternalServerError)
		return
	}
	file.Close()

	slog.Debug("stored blob", "sha256", sha256, "size", len(body))

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, `{"status":"ok","hash":"%s","url":"https://%s/%s"}`, sha256, config.RelayURL, sha256)
}

func handleBlossomDownload(w http.ResponseWriter, r *http.Request) {
	// Extract SHA256 from path
	sha256 := strings.TrimPrefix(r.URL.Path, "/")
	if sha256 == "" || len(sha256) != 64 {
		http.Error(w, "Invalid SHA256 hash", http.StatusBadRequest)
		return
	}

	// Load blob from filesystem
	file, err := fs.Open(config.BlossomPath + sha256)
	if err != nil {
		slog.Debug("Blob not found", "sha256", sha256)
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}
	defer file.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, file)
}

func handleBlossomDelete(w http.ResponseWriter, r *http.Request) {
	// Extract SHA256 from path
	sha256 := strings.TrimPrefix(r.URL.Path, "/")
	if sha256 == "" || len(sha256) != 64 {
		http.Error(w, "Invalid SHA256 hash", http.StatusBadRequest)
		return
	}

	// Verify NIP-98 auth header
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, "Missing Authorization header", http.StatusUnauthorized)
		return
	}

	// Delete from filesystem
	if err := fs.Remove(config.BlossomPath + sha256); err != nil {
		slog.Error("Failed to delete blob", "sha256", sha256, "error", err)
		http.Error(w, "Failed to delete blob", http.StatusInternalServerError)
		return
	}

	slog.Debug("deleted blob", "sha256", sha256)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"status":"ok"}`)
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

// Dummy main() function required for buildmode=c-archive
// This is never called; entry points are the exported C functions above
func main() {
}
