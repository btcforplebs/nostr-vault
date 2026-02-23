package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"runtime"
	"text/template"
	"time"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/fiatjaf/eventstore/badger"
	"github.com/fiatjaf/eventstore/lmdb"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// Global variables used by both desktop (main.go) and iOS (cshared.go)
var (
	pool   *nostr.SimplePool
	config Config
	fs     afero.Fs
)

// Relay instances — re-created on each initRelays() call so HTTP muxes are fresh.
var (
	privateRelay *khatru.Relay
	privateDB    DBBackend
)

var (
	chatRelay *khatru.Relay
	chatDB    DBBackend
)

var (
	outboxRelay *khatru.Relay
	outboxDB    DBBackend
)

var (
	inboxRelay *khatru.Relay
	inboxDB    DBBackend
)

var (
	blossomDB     DBBackend
	blossomServer *blossom.BlossomServer
	dbs           map[string]DBBackend
)

type DBBackend interface {
	Init() error
	Close()
	CountEvents(ctx context.Context, filter nostr.Filter) (int64, error)
	DeleteEvent(ctx context.Context, evt *nostr.Event) error
	QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error)
	SaveEvent(ctx context.Context, evt *nostr.Event) error
	ReplaceEvent(ctx context.Context, evt *nostr.Event) error
	Serial() []byte
}

func newDBBackend(path string) DBBackend {
	switch config.DBEngine {
	case "lmdb":
		return newLMDBBackend(path)
	case "badger":
		return &badger.BadgerBackend{
			Path: path,
			// Limit vlog file size to 64 MB so iOS can mmap them.
			// BadgerDB's default is ~2 GB which exceeds the virtual
			// address space available to sandboxed iOS processes.
			BadgerOptionsModifier: func(opts badgerdb.Options) badgerdb.Options {
				return opts.WithValueLogFileSize(1 << 26) // 64 MiB
			},
		}
	default:
		return newLMDBBackend(path)
	}
}

func newLMDBBackend(path string) *lmdb.LMDBBackend {
	mapSize := config.LmdbMapSize
	if mapSize == 0 && runtime.GOOS == "ios" {
		// iOS has strict memory mapping limits per process
		mapSize = 256 << 20 // 256 MB
	}
	return &lmdb.LMDBBackend{
		Path:    path,
		MapSize: mapSize,
	}
}

func initDBs() error {
	return GranularInitDBs([]string{"private", "chat", "outbox", "inbox", "blossom"})
}

func GranularInitDBs(names []string) error {
	if dbs == nil {
		dbs = make(map[string]DBBackend)
	}

	for i, name := range names {
		path := "db/" + name
		slog.Info(fmt.Sprintf("Initializing %s database (%d/%d)", name, i+1, len(names)))
		db := newDBBackend(path)
		if err := db.Init(); err != nil {
			return fmt.Errorf("%sDB init failed: %w", name, err)
		}
		dbs[name] = db
		slog.Info(fmt.Sprintf("✓ %s database ready", name))

		// Assign to global variables for backward compatibility
		switch name {
		case "private":
			privateDB = db
		case "chat":
			chatDB = db
		case "outbox":
			outboxDB = db
		case "inbox":
			inboxDB = db
		case "blossom":
			blossomDB = db
		}
	}

	return nil
}

func CloseDBs() {
	if dbs != nil {
		for name, db := range dbs {
			if db != nil {
				slog.Info("Closing database", "name", name)
				db.Close()
				dbs[name] = nil
			}
		}
	}
}

func initRelays(ctx context.Context) error {
	// Re-create relay instances on each call so their internal HTTP muxes are fresh.
	// This prevents "pattern already registered" panics when the relay is restarted
	// in C-shared mode (e.g. after import completes).
	privateRelay = khatru.NewRelay()
	chatRelay = khatru.NewRelay()
	outboxRelay = khatru.NewRelay()
	inboxRelay = khatru.NewRelay()

	if err := initDBs(); err != nil {
		return err
	}

	initRelayLimits()

	privateRelay.Info.Name = config.PrivateRelayName
	privateRelay.Info.PubKey = nPubToPubkey(config.PrivateRelayNpub)
	privateRelay.Info.Description = config.PrivateRelayDescription
	privateRelay.Info.Icon = config.PrivateRelayIcon
	privateRelay.Info.Version = config.RelayVersion
	privateRelay.Info.Software = config.RelaySoftware
	privateRelay.ServiceURL = "https://" + config.RelayURL + "/private"

	if !privateRelayLimits.AllowEmptyFilters {
		privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !privateRelayLimits.AllowComplexFilters {
		privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.NoComplexFilters)
	}
	privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.MustAuth, MustBeWhitelistedToQuery)

	privateRelay.RejectEvent = append(privateRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		policies.EventIPRateLimiter(
			privateRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(privateRelayLimits.EventIPLimiterInterval),
			privateRelayLimits.EventIPLimiterMaxTokens,
		),
		MustBeWhitelistedToPost,
	)

	privateRelay.RejectConnection = append(privateRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			privateRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(privateRelayLimits.ConnectionRateLimiterInterval),
			privateRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	privateRelay.OnConnect = append(privateRelay.OnConnect, khatru.RequestAuth)

	privateRelay.StoreEvent = append(privateRelay.StoreEvent, privateDB.SaveEvent)
	privateRelay.QueryEvents = append(privateRelay.QueryEvents, privateDB.QueryEvents)
	privateRelay.DeleteEvent = append(privateRelay.DeleteEvent, privateDB.DeleteEvent)
	privateRelay.CountEvents = append(privateRelay.CountEvents, privateDB.CountEvents)
	privateRelay.ReplaceEvent = append(privateRelay.ReplaceEvent, privateDB.ReplaceEvent)

	mux := privateRelay.Router()

	mux.HandleFunc("GET /private", func(w http.ResponseWriter, r *http.Request) {
		tmpl := template.Must(template.ParseFiles("templates/index.html"))
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.PrivateRelayName,
			RelayPubkey:      nPubToPubkey(config.PrivateRelayNpub),
			RelayDescription: config.PrivateRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/private",
		}
		err := tmpl.Execute(w, data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	chatRelay.Info.Name = config.ChatRelayName
	chatRelay.Info.PubKey = nPubToPubkey(config.ChatRelayNpub)
	chatRelay.Info.Description = config.ChatRelayDescription
	chatRelay.Info.Icon = config.ChatRelayIcon
	chatRelay.Info.Version = config.RelayVersion
	chatRelay.Info.Software = config.RelaySoftware
	chatRelay.ServiceURL = "https://" + config.RelayURL + "/chat"

	if !chatRelayLimits.AllowEmptyFilters {
		chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !chatRelayLimits.AllowComplexFilters {
		chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.NoComplexFilters)
	}
	chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.MustAuth, MustBeInWotToQuery)

	chatRelay.RejectEvent = append(chatRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		policies.EventIPRateLimiter(
			chatRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(chatRelayLimits.EventIPLimiterInterval),
			chatRelayLimits.EventIPLimiterMaxTokens,
		),
		MustNotBeBlacklistedToPost,
		MustBeInWotToPost,
		EventMustBeChatRelated,
	)

	chatRelay.RejectConnection = append(chatRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			chatRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(chatRelayLimits.ConnectionRateLimiterInterval),
			chatRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	chatRelay.OnConnect = append(chatRelay.OnConnect, khatru.RequestAuth)

	chatRelay.StoreEvent = append(chatRelay.StoreEvent, chatDB.SaveEvent)
	chatRelay.QueryEvents = append(chatRelay.QueryEvents, chatDB.QueryEvents)
	chatRelay.DeleteEvent = append(chatRelay.DeleteEvent, chatDB.DeleteEvent)
	chatRelay.CountEvents = append(chatRelay.CountEvents, chatDB.CountEvents)
	chatRelay.ReplaceEvent = append(chatRelay.ReplaceEvent, chatDB.ReplaceEvent)

	mux = chatRelay.Router()

	mux.HandleFunc("GET /chat", func(w http.ResponseWriter, r *http.Request) {
		tmpl := template.Must(template.ParseFiles("templates/index.html"))
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.ChatRelayName,
			RelayPubkey:      nPubToPubkey(config.ChatRelayNpub),
			RelayDescription: config.ChatRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/chat",
		}
		err := tmpl.Execute(w, data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	outboxRelay.Info.Name = config.OutboxRelayName
	outboxRelay.Info.PubKey = nPubToPubkey(config.OutboxRelayNpub)
	outboxRelay.Info.Description = config.OutboxRelayDescription
	outboxRelay.Info.Icon = config.OutboxRelayIcon
	outboxRelay.Info.Version = config.RelayVersion
	outboxRelay.Info.Software = config.RelaySoftware
	outboxRelay.ServiceURL = "https://" + config.RelayURL

	if !outboxRelayLimits.AllowEmptyFilters {
		outboxRelay.RejectFilter = append(outboxRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !outboxRelayLimits.AllowComplexFilters {
		outboxRelay.RejectFilter = append(outboxRelay.RejectFilter, policies.NoComplexFilters)
	}

	outboxRelay.RejectEvent = append(outboxRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		policies.EventIPRateLimiter(
			outboxRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(outboxRelayLimits.EventIPLimiterInterval),
			outboxRelayLimits.EventIPLimiterMaxTokens,
		),
		MustBeWhitelistedToPost,
	)

	outboxRelay.RejectConnection = append(outboxRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			outboxRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(outboxRelayLimits.ConnectionRateLimiterInterval),
			outboxRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	outboxRelay.StoreEvent = append(outboxRelay.StoreEvent, outboxDB.SaveEvent, func(ctx context.Context, event *nostr.Event) error {
		go blast(ctx, event)
		return nil
	})
	outboxRelay.QueryEvents = append(outboxRelay.QueryEvents, outboxDB.QueryEvents)
	outboxRelay.DeleteEvent = append(outboxRelay.DeleteEvent, outboxDB.DeleteEvent)
	outboxRelay.CountEvents = append(outboxRelay.CountEvents, outboxDB.CountEvents)
	outboxRelay.ReplaceEvent = append(outboxRelay.ReplaceEvent, outboxDB.ReplaceEvent)

	mux = outboxRelay.Router()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		tmpl := template.Must(template.ParseFiles("templates/index.html"))
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.OutboxRelayName,
			RelayPubkey:      nPubToPubkey(config.OutboxRelayNpub),
			RelayDescription: config.OutboxRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/outbox",
		}
		err := tmpl.Execute(w, data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	blossomServer = blossom.New(outboxRelay, "https://"+config.RelayURL)
	blossomServer.Store = blossom.EventStoreBlobIndexWrapper{Store: blossomDB, ServiceURL: blossomServer.ServiceURL}
	blossomServer.StoreBlob = append(blossomServer.StoreBlob, func(ctx context.Context, sha256 string, ext string, body []byte) error {
		slog.Debug("storing blob", "sha256", sha256, "ext", ext)
		file, err := fs.Create(config.BlossomPath + sha256)
		if err != nil {
			return err
		}
		if _, err := io.Copy(file, bytes.NewReader(body)); err != nil {
			return err
		}
		return nil
	})
	blossomServer.LoadBlob = append(blossomServer.LoadBlob, loadBlob)
	blossomServer.DeleteBlob = append(blossomServer.DeleteBlob, func(ctx context.Context, sha256 string, ext string) error {
		slog.Debug("deleting blob", "sha256", sha256, "ext", ext)
		return fs.Remove(config.BlossomPath + sha256)
	})
	blossomServer.RejectUpload = append(blossomServer.RejectUpload, func(ctx context.Context, event *nostr.Event, size int, ext string) (bool, string, int) {
		if _, ok := config.WhitelistedPubKeys[event.PubKey]; ok {
			return false, ext, size
		}

		return true, "only media signed by whitelisted pubkeys are allowed", 403
	})
	migrateBlossomMetadata(ctx, blossomServer)

	inboxRelay.Info.Name = config.InboxRelayName
	inboxRelay.Info.PubKey = nPubToPubkey(config.InboxRelayNpub)
	inboxRelay.Info.Description = config.InboxRelayDescription
	inboxRelay.Info.Icon = config.InboxRelayIcon
	inboxRelay.Info.Version = config.RelayVersion
	inboxRelay.Info.Software = config.RelaySoftware
	inboxRelay.ServiceURL = "https://" + config.RelayURL + "/inbox"

	if !inboxRelayLimits.AllowEmptyFilters {
		inboxRelay.RejectFilter = append(inboxRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !inboxRelayLimits.AllowComplexFilters {
		inboxRelay.RejectFilter = append(inboxRelay.RejectFilter, policies.NoComplexFilters)
	}

	inboxRelay.RejectEvent = append(inboxRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		policies.EventIPRateLimiter(
			inboxRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(inboxRelayLimits.EventIPLimiterInterval),
			inboxRelayLimits.EventIPLimiterMaxTokens,
		),
		OnlyGiftWrappedDMs,
		MustNotBeBlacklistedToPost,
		MustBeInWotToPost,
		MustTagWhitelistedPubKey,
	)

	inboxRelay.RejectConnection = append(inboxRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			inboxRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(inboxRelayLimits.ConnectionRateLimiterInterval),
			inboxRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	inboxRelay.StoreEvent = append(inboxRelay.StoreEvent, inboxDB.SaveEvent)
	inboxRelay.QueryEvents = append(inboxRelay.QueryEvents, inboxDB.QueryEvents)
	inboxRelay.DeleteEvent = append(inboxRelay.DeleteEvent, inboxDB.DeleteEvent)
	inboxRelay.CountEvents = append(inboxRelay.CountEvents, inboxDB.CountEvents)
	inboxRelay.ReplaceEvent = append(inboxRelay.ReplaceEvent, inboxDB.ReplaceEvent)

	mux = inboxRelay.Router()

	mux.HandleFunc("GET /inbox", func(w http.ResponseWriter, r *http.Request) {
		tmpl := template.Must(template.ParseFiles("templates/index.html"))
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.InboxRelayName,
			RelayPubkey:      nPubToPubkey(config.InboxRelayNpub),
			RelayDescription: config.InboxRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/inbox",
		}
		err := tmpl.Execute(w, data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	return nil
}

// Shared helper functions used by both main.go and cshared.go

func dynamicRelayHandler(w http.ResponseWriter, r *http.Request) {
	var relay *khatru.Relay
	relayType := r.URL.Path

	switch relayType {
	case "/private":
		relay = privateRelay
	case "/chat":
		relay = chatRelay
	case "/inbox":
		relay = inboxRelay
	case "":
		relay = outboxRelay
	default:
		relay = outboxRelay
	}

	relay.ServeHTTP(w, r)
}

func getLogLevelFromConfig() slog.Level {
	switch config.LogLevel {
	case "DEBUG":
		return slog.LevelDebug
	case "INFO":
		return slog.LevelInfo
	case "WARN":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo // Default level
	}
}
