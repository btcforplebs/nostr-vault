//go:build cshared

package main

import "C"

import (
	"C"
	"context"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/bitvora/haven/pkg/wot"
	"github.com/nbd-wtf/go-nostr"
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

	log.Println("🚀 HAVEN", config.RelayVersion, "is booting up (C-Shared Mode)")

	if importMode {
		ensureImportRelays()
		runImport(csharedCtx)
		log.Println("✅ Import completed in C-Shared mode")
		return
	}

	ensureImportRelays()
	wotModel := wot.NewSimpleInMemory(
		pool,
		config.WhitelistedPubKeys,
		config.ImportSeedRelays,
		config.WotDepth,
		config.WotMinimumFollowers,
		config.WotFetchTimeoutSeconds,
	)
	wot.Initialize(csharedCtx, wotModel)
	if err := initRelays(csharedCtx); err != nil {
		log.Println("🚫 error initializing databases/relays:", err)
		return
	}
	go func() {
		go subscribeInboxAndChat(csharedCtx)
		go startPeriodicCloudBackups(csharedCtx)
		go wot.PeriodicRefresh(csharedCtx, config.WotRefreshInterval)
	}()

	// Use a fresh ServeMux each cycle so stop/start never panics on
	// duplicate pattern registration in the default mux.
	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("templates/static"))))
	mux.HandleFunc("/", dynamicRelayHandler)

	addr := fmt.Sprintf("%s:%d", config.RelayBindAddress, config.RelayPort)
	globalServer = &http.Server{Addr: addr, Handler: mux}

	log.Printf("🔗 listening at %s", addr)
	go func() {
		if err := globalServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Println("🚫 error starting server:", err)
		}
	}()
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
