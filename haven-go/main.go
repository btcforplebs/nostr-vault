//go:build !cshared

package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/bitvora/haven/pkg/wot"
)

func main() {
	if isCShared() {
		return
	}
	config = loadConfig()
	nostr.InfoLogger = log.New(io.Discard, "", 0)
	slog.SetLogLoggerLevel(getLogLevelFromConfig())
	green := "\033[32m"
	reset := "\033[0m"
	fmt.Println(green + art + reset)

	mainCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	fs = afero.NewOsFs()
	if err := fs.MkdirAll(config.BlossomPath, 0755); err != nil {
		log.Fatal("🚫 error creating blossom path:", err)
	}

	pool = nostr.NewSimplePool(mainCtx,
		nostr.WithPenaltyBox(),
		nostr.WithRelayOptions(
			nostr.WithRequestHeader{
				"User-Agent": []string{config.UserAgent},
			}),
	)

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "backup":
			runBackup(mainCtx)
			return
		case "restore":
			runRestore(mainCtx)
			return
		case "import":
			if !ensureImportRelays() {
				log.Fatal("🚫 Import aborted: could not connect to any seed relays")
			}
			runImport(mainCtx)
			return
		case "help":
			printHelp()
			return
		}

		if os.Args[1] == "-h" || os.Args[1] == "--help" {
			printHelp()
			return
		}
	}

	flag.Parse()

	log.Println("🚀 HAVEN", config.RelayVersion, "is booting up")
	defer log.Println("🔌 HAVEN is shutting down")
	defer CloseDBs()
	log.Println("👥 Number of whitelisted pubkeys:", len(config.WhitelistedPubKeys))
	log.Println("🚷 Number of blacklisted pubkeys:", len(config.BlacklistedPubKeys))

	if !ensureImportRelays() {
		log.Println("⚠️ No seed relays reachable — starting relay without inbox subscription")
	}
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
	go wot.Initialize(mainCtx, wotModel)
	if err := initRelays(mainCtx); err != nil {
		log.Fatal("🚫 error initializing databases/relays:", err)
	}
	go func() {
		go subscribeInboxAndChat(mainCtx)
		go startPeriodicCloudBackups(mainCtx)
		go wot.PeriodicRefresh(mainCtx, config.WotRefreshInterval)
	}()

	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("templates/static"))))

	// Blossom + relay router - check method and route accordingly
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
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

	log.Printf("🔗 listening at %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal("🚫 error starting server:", err)
	}
}

func printHelp() {
	fmt.Println("haven is a personal nostr relay.")
	fmt.Println()
	fmt.Println("usage: haven [command]")
	fmt.Println()
	fmt.Println("commands:")
	fmt.Println("  backup  - backup the database")
	fmt.Println("  restore - restore the database")
	fmt.Println("  import  - import notes from seed relays")
	fmt.Println("  help    - show this help message")
	fmt.Println()
	fmt.Println("if no command is provided, the relay starts by default.")
	fmt.Println()
	fmt.Println("run 'haven [command] --help' for more information on a command.")
}


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

	// TODO: Verify NIP-98 signature
	// For now, accept any auth (in production, validate the signature)

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

	// TODO: Verify NIP-98 signature and ownership

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

