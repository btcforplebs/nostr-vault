package blossom

import (
	"context"
	"io"
	"net/http"
	"strings"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

type BlossomServer struct {
	ServiceURL string
	Store      BlobIndex

	// StoreBlob files a received blob. Unused when SpoolBlob is set: the
	// spool's Commit stores it.
	StoreBlob     []func(ctx context.Context, sha256 string, ext string, body io.Reader) error
	LoadBlob      []func(ctx context.Context, sha256 string, ext string) (io.ReadSeeker, error)
	DeleteBlob    []func(ctx context.Context, sha256 string, ext string) error
	ReceiveReport []func(ctx context.Context, reportEvt *nostr.Event) error
	RedirectGet   []func(ctx context.Context, sha256 string, ext string) (url string, code int, err error)

	// RejectUpload runs on /upload and /mirror before any body byte is read
	// or any URL fetched: size is the declared length (0 when unknown), ext
	// what the request headers say.
	RejectUpload []func(ctx context.Context, auth *nostr.Event, size int, ext string) (bool, string, int)
	// RejectBlob runs once the bytes are received and hashed, before
	// anything is kept or stored.
	RejectBlob   []func(ctx context.Context, auth *nostr.Event, sha256 string, size int) (bool, string, int)
	RejectGet    []func(ctx context.Context, auth *nostr.Event, sha256 string, ext string) (bool, string, int)
	RejectList   []func(ctx context.Context, auth *nostr.Event, pubkey string) (bool, string, int)
	RejectDelete []func(ctx context.Context, auth *nostr.Event, sha256 string, ext string) (bool, string, int)

	// SpoolBlob, when set, gives each receive a place for its bytes so a
	// blob is never held whole in memory. Unset: a memory spool.
	SpoolBlob func(ctx context.Context) (Spool, error)
	// MaxUploadSize caps one blob in bytes, 0 for no cap. Over it: 413 with
	// TooLargeReason as X-Reason.
	MaxUploadSize int64
}

// ServerOption represents a functional option for configuring a BlossomServer
type ServerOption func(*BlossomServer)

// New creates a new BlossomServer with the given relay and service URL
// Optional configuration can be provided via functional options
func New(rl *khatru.Relay, serviceURL string) *BlossomServer {
	bs := &BlossomServer{
		ServiceURL: serviceURL,
	}

	base := rl.Router()
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/upload" {
			if r.Method == "PUT" {
				bs.handleUpload(w, r)
				return
			} else if r.Method == "HEAD" {
				bs.handleUploadCheck(w, r)
				return
			}
		}
		if r.URL.Path == "/media" {
			bs.handleMedia(w, r)
			return
		}
		if r.URL.Path == "/mirror" && r.Method == "PUT" {
			bs.handleMirror(w, r)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/list/") && r.Method == "GET" {
			bs.handleList(w, r)
			return
		}

		if (len(r.URL.Path) == 65 || strings.Index(r.URL.Path, ".") == 65) && strings.Index(r.URL.Path[1:], "/") == -1 {
			if r.Method == "HEAD" {
				bs.handleHasBlob(w, r)
				return
			} else if r.Method == "GET" {
				bs.handleGetBlob(w, r)
				return
			} else if r.Method == "DELETE" {
				bs.handleDelete(w, r)
				return
			}
		}

		if r.URL.Path == "/report" {
			if r.Method == "PUT" {
				bs.handleReport(w, r)
				return
			}
		}

		base.ServeHTTP(w, r)
	})

	rl.SetRouter(mux)

	return bs
}
