//go:build !cshared && !(js && wasm)

package main

// The Linux box as B (One Vault spec E3): havend asks the engine, over a
// Unix socket only it can reach, to run a first copy or a catch-up with one
// of the owner's other vaults. havend gets the loopback base (and, for a
// first copy, the start proof signed with the box's own mesh key) from
// nv-mesh's dial.sock; the engine never signs anything and never holds an
// account key. The copy and catch-up are the apps' own (copyv2_client.go,
// copyv2_sync.go), so the box keeps every account a copy carries, the same
// as a Mac.
//
// The socket is HAVEN_BOX_CONTROL_SOCK (havend puts it in a 0700 dir and the
// engine makes it 0600). Unset: no control, as before. It is never on the
// relay's port: the front door proxies that port to the internet.
//
//	POST /copy/first {"peer":"npub1…","base":"http://127.0.0.1:…","auth":"<base64 27235>"}
//	POST /copy/sync  {"peer":"npub1…","base":"http://127.0.0.1:…"}
//	GET  /copy/state?peer=npub1…&peer=…
//
// Both POSTs start the run and answer 202; 409 while another copy or
// catch-up runs (one at a time, copyRuns). State is per device: the
// device's catch-up mark, whether the box holds a copy token from it, and
// the last run's outcome, kept in box_copy_state.json.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr/nip19"
)

const boxCopyStateFile = "box_copy_state.json"

// boxCopyRun is one device's last first copy or catch-up.
type boxCopyRun struct {
	Kind     string `json:"kind"` // "first" or "sync"
	Started  int64  `json:"started"`
	Finished int64  `json:"finished,omitempty"`
	// Error is the contract code (copyErrorCode); "" when it finished well.
	Error string `json:"error,omitempty"`
	Got   int    `json:"got,omitempty"`
	Sent  int    `json:"sent,omitempty"`
	Files int    `json:"files,omitempty"`
	Gone  int    `json:"gone,omitempty"`
}

// boxCopyDevice is what GET /copy/state says about one device.
type boxCopyDevice struct {
	Peer string `json:"peer"`
	// Token: the box holds a copy token from this vault, so it can catch up.
	// Without one only a first copy can start (it brings the token).
	Token    bool        `json:"token"`
	SyncedAt int64       `json:"syncedAt,omitempty"`
	Last     *boxCopyRun `json:"last,omitempty"`
}

type boxCopyState struct {
	// Busy: a copy or catch-up runs (any, the apps' own included), so a new
	// one would be refused. Set before the run's goroutine starts.
	Busy    bool            `json:"busy"`
	Running string          `json:"running,omitempty"` // the device a box run is with now
	Devices []boxCopyDevice `json:"devices"`
}

// boxCopies records runs per device (by copyPeerKey, as the catch-up marks).
type boxCopies struct {
	mu      sync.Mutex
	path    string
	running string
	last    map[string]boxCopyRun
	loaded  bool
	now     func() time.Time
}

var boxCopy = &boxCopies{path: boxCopyStateFile, now: time.Now}

func (b *boxCopies) load() {
	if b.loaded {
		return
	}
	b.loaded = true
	b.last = map[string]boxCopyRun{}
	if raw, err := os.ReadFile(b.path); err == nil {
		_ = json.Unmarshal(raw, &b.last)
	}
}

func (b *boxCopies) save() {
	raw, _ := json.Marshal(b.last)
	tmp := b.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, b.path)
	}
}

func (b *boxCopies) begin(peer, kind string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.load()
	b.running = peer
	b.last[copyPeerKey(peer)] = boxCopyRun{Kind: kind, Started: b.now().Unix()}
	b.save()
}

func (b *boxCopies) end(peer string, res copySyncResult, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.load()
	b.running = ""
	run := b.last[copyPeerKey(peer)]
	run.Finished = b.now().Unix()
	run.Got, run.Sent, run.Files, run.Gone = res.Got, res.Sent, res.Files, res.Gone
	if err != nil {
		run.Error = copyErrorCode(err)
	}
	b.last[copyPeerKey(peer)] = run
	b.save()
}

func (b *boxCopies) state(peers []string) boxCopyState {
	marks := func() map[string]int64 {
		copySyncMu.Lock()
		defer copySyncMu.Unlock()
		return loadCopySync()
	}()
	b.mu.Lock()
	defer b.mu.Unlock()
	b.load()
	copyRuns.mu.Lock()
	busy := copyRuns.running
	copyRuns.mu.Unlock()
	out := boxCopyState{Busy: busy, Running: b.running, Devices: []boxCopyDevice{}}
	for _, p := range peers {
		d := boxCopyDevice{Peer: p, Token: copyPeerToken(p) != "", SyncedAt: marks[copyPeerKey(p)]}
		if run, ok := b.last[copyPeerKey(p)]; ok {
			d.Last = &run
		}
		out.Devices = append(out.Devices, d)
	}
	return out
}

// boxFirstCopy: a first copy from peer, started with the box's own proof.
// No relay setup job afterwards (the Mac's startCopyFrom runs one): the box
// imports from relays on its own schedule.
func boxFirstCopy(ctx context.Context, spawn func(string, func()), peer, base, auth string) int {
	return copyRuns.begin(ctx, spawn, "copyv2.boxFirst", func(cctx context.Context) {
		boxCopy.begin(peer, "first")
		err := newCopyClient(peer, base).run(cctx, auth)
		boxCopy.end(peer, copySyncResult{}, err)
		if err != nil {
			log.Printf("📦 box: first copy from %s stopped: %s", copyPeerKey(peer), copyErrorCode(err))
		}
	})
}

// boxCatchUp: one full catch-up with peer (notes both ways, its own files).
func boxCatchUp(ctx context.Context, spawn func(string, func()), peer, base string) int {
	return copyRuns.begin(ctx, spawn, "copyv2.boxSync", func(cctx context.Context) {
		boxCopy.begin(peer, "sync")
		res, err := newCopyClient(peer, base).sync(cctx)
		boxCopy.end(peer, res, err)
		if err != nil {
			log.Printf("📦 box: catch-up with %s stopped: %s", copyPeerKey(peer), copyErrorCode(err))
		}
	})
}

// boxPeer: an npub, re-encoded (the form havend and nv-mesh use).
func boxPeer(s string) (string, bool) {
	prefix, v, err := nip19.Decode(strings.TrimSpace(s))
	if err != nil || prefix != "npub" {
		return "", false
	}
	npub, err := nip19.EncodePublicKey(v.(string))
	return npub, err == nil
}

// boxBase: a loopback http base, the only kind nv-mesh's dial gives.
func boxBase(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.User != nil || u.RawQuery != "" {
		return false
	}
	p, err := strconv.Atoi(u.Port())
	return err == nil && p > 0 && p < 65536
}

// boxControl is the socket's handler. spawn runs the copy (runsafe.Go).
func boxControl(ctx context.Context, spawn func(string, func())) http.Handler {
	mux := http.NewServeMux()
	start := func(w http.ResponseWriter, r *http.Request, first bool) {
		var in struct{ Peer, Base, Auth string }
		if err := json.NewDecoder(io.LimitReader(r.Body, 16<<10)).Decode(&in); err != nil {
			copyJSON(w, http.StatusBadRequest, map[string]string{"error": "body is not JSON"})
			return
		}
		peer, ok := boxPeer(in.Peer)
		if !ok || !boxBase(in.Base) || (first && strings.TrimSpace(in.Auth) == "") {
			copyJSON(w, http.StatusBadRequest, map[string]string{"error": "needs peer (npub), a loopback base and, for a first copy, auth"})
			return
		}
		var rc int
		if first {
			rc = boxFirstCopy(ctx, spawn, peer, in.Base, strings.TrimSpace(in.Auth))
		} else {
			rc = boxCatchUp(ctx, spawn, peer, in.Base)
		}
		if rc != 0 {
			copyJSON(w, http.StatusConflict, map[string]string{"error": "a copy or catch-up is running"})
			return
		}
		copyJSON(w, http.StatusAccepted, map[string]string{"peer": peer})
	}
	mux.HandleFunc("POST /copy/first", func(w http.ResponseWriter, r *http.Request) { start(w, r, true) })
	mux.HandleFunc("POST /copy/sync", func(w http.ResponseWriter, r *http.Request) { start(w, r, false) })
	mux.HandleFunc("GET /copy/state", func(w http.ResponseWriter, r *http.Request) {
		peers := []string{}
		for _, p := range r.URL.Query()["peer"] {
			if npub, ok := boxPeer(p); ok {
				peers = append(peers, npub)
			}
		}
		copyJSON(w, http.StatusOK, boxCopy.state(peers))
	})
	return mux
}

// startBoxControlFromEnv serves boxControl on HAVEN_BOX_CONTROL_SOCK until ctx
// ends. Unset: nothing.
func startBoxControlFromEnv(ctx context.Context, spawn func(string, func())) error {
	path := strings.TrimSpace(hostGetenv("HAVEN_BOX_CONTROL_SOCK"))
	if path == "" {
		return nil
	}
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSocket == 0 {
			return errors.New(path + " exists and is not a socket")
		}
		_ = os.Remove(path) // the last engine's
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		l.Close()
		return err
	}
	srv := &http.Server{Handler: boxControl(ctx, spawn), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	go func() {
		if err := srv.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("🚫 box control: %v", err)
		}
	}()
	log.Printf("📦 box control on %s", path)
	return nil
}
