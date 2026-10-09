package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// meshMaxUploadBytes caps one blob pushed over the mesh. khatru's Blossom
// upload allocates Content-Length bytes up front and holds the whole blob in
// memory, so the cap is checked before the body is touched.
const meshMaxUploadBytes = 256 << 20

// Mesh server limits. A peer that sends headers and then goes quiet must not
// hold a goroutine or a connection open indefinitely. Vars so tests can shrink them.
var (
	meshReadHeaderTimeout = 10 * time.Second
	meshIdleTimeout       = 60 * time.Second
	// One blob in or out may take this long; set per request, since a
	// server-wide write timeout would also cut long-lived websockets.
	meshTransferTimeout = 30 * time.Minute
	// An upload must make progress at least this often, and after the
	// grace period average at least meshMinRate bytes a second.
	meshIdleRead  = 30 * time.Second
	meshRateGrace = 30 * time.Second
	meshMinRate   = 64.0 * 1024
	// At most this many mesh connections at once, each at most this long.
	meshMaxConns        = 32
	meshConnMaxLifetime = 30 * time.Minute
)

// meshUploadSlots: one owner upload at a time. khatru holds the whole blob
// in memory, so this bounds the kiosk at one meshMaxUploadBytes buffer.
var meshUploadSlots = make(chan struct{}, 1)

// newMeshServer is the mesh port's HTTP server.
func newMeshServer(addr string) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           http.HandlerFunc(meshHandler),
		ReadHeaderTimeout: meshReadHeaderTimeout,
		IdleTimeout:       meshIdleTimeout,
		MaxHeaderBytes:    64 << 10,
	}
}

type meshPeerKey struct{}

// isMeshRequest reports whether r came in through the mesh port. Mesh traffic
// arrives from 127.0.0.1 like the owner's own app, so loopback alone must
// never earn a free pass.
func isMeshRequest(r *http.Request) bool {
	return r != nil && r.Context().Value(meshPeerKey{}) != nil
}

// isMeshConn reports whether a relay callback runs on a mesh websocket.
func isMeshConn(ctx context.Context) bool {
	conn := khatru.GetConnection(ctx)
	return conn != nil && isMeshRequest(conn.Request)
}

// meshHandler is the whole mesh door. A mesh peer is an unknown remote
// client (NIP-F1); the owner's other phone gets in only with the owner's
// signature:
//   - GET/HEAD /<sha256>[.ext]: read one blob (meshBlobHandler).
//   - PUT/HEAD /upload: Blossom upload, owner-signed kind 24242 or 403
//     (checked here, before khatru allocates), at most meshMaxUploadBytes,
//     one at a time.
//   - websocket on /: outbox relay, EVENTs signed by the owner only
//     (meshOwnerEventsOnly), no queries.
//
// Everything else is 404.
func meshHandler(w http.ResponseWriter, r *http.Request) {
	// khatru takes the client IP from X-Forwarded-For, which would let one
	// peer pick a fresh rate bucket per connection.
	r.Header.Del("X-Forwarded-For")
	r.Header.Del("X-Real-Ip")
	r.Header.Del("X-Forwarded-Host")
	r.Header.Del("X-Forwarded-Proto")

	switch {
	case r.URL.Path == "/upload" && (r.Method == http.MethodPut || r.Method == http.MethodHead):
		// Check whose key signed the upload before khatru sees it: khatru
		// allocates Content-Length bytes before its RejectUpload whitelist
		// runs, so a throwaway key could make the kiosk hold 256 MB.
		auth, code, msg := meshUploadAuthorized(r)
		if code != 0 {
			http.Error(w, msg, code)
			return
		}
		if r.Method == http.MethodPut {
			if r.ContentLength <= 0 {
				http.Error(w, "Content-Length required", http.StatusLengthRequired)
				return
			}
			if r.ContentLength > meshMaxUploadBytes {
				http.Error(w, "blob too large for the mesh", http.StatusRequestEntityTooLarge)
				return
			}
			select {
			case meshUploadSlots <- struct{}{}:
				defer func() { <-meshUploadSlots }()
			default:
				w.Header().Set("Retry-After", "30")
				http.Error(w, "another upload is in progress", http.StatusServiceUnavailable)
				return
			}
			// Spend the auth on admission: an attempt that stalls or fails
			// cannot be repeated with the same token (senders sign per try).
			if !meshAuthUse(auth) {
				http.Error(w, "authorization already used", http.StatusForbidden)
				return
			}
			// Read the body here, so memory grows with bytes that actually
			// arrive rather than with the Content-Length a peer claims.
			body, hash, err := readMeshBody(w, r)
			if err != nil {
				http.Error(w, "upload body: "+err.Error(), http.StatusBadRequest)
				return
			}
			if auth.Tags.FindWithValue("x", hash) == nil {
				// A token signed for another blob (a public mirror holds
				// one for its hour) cannot put anything else here.
				http.Error(w, "authorization does not cover this blob", http.StatusForbidden)
				return
			}
			r.Body = body
			r.Header.Set("Content-Length", strconv.FormatInt(r.ContentLength, 10))
		}
		// Keep the request on the Blossom mux: khatru routes websocket,
		// NIP-11 and NIP-86 by header before the path.
		r.Header.Del("Upgrade")
		r.Header.Del("Accept")
		if r.Header.Get("Content-Type") == "application/nostr+json+rpc" {
			r.Header.Del("Content-Type")
		}
		dynamicRelayHandler(w, markMesh(r))
	case r.URL.Path == "/" && r.Method == http.MethodGet && r.Header.Get("Upgrade") == "websocket":
		r.Header.Del("Accept")
		r.Header.Del("Content-Type")
		dynamicRelayHandler(w, markMesh(r))
	default:
		setTransferDeadline(w)
		meshBlobHandler(w, r)
	}
}

func setTransferDeadline(w http.ResponseWriter) {
	rc := http.NewResponseController(w)
	deadline := time.Now().Add(meshTransferTimeout)
	_ = rc.SetReadDeadline(deadline)
	_ = rc.SetWriteDeadline(deadline)
}

// meshUploadAuthorized: the upload's kind 24242 must be signed by a
// whitelisted key, unexpired, for "upload". Returns the event, or an HTTP
// status and reason. khatru re-checks the whitelist afterwards.
func meshUploadAuthorized(r *http.Request) (*nostr.Event, int, string) {
	token := r.Header.Get("Authorization")
	if !strings.HasPrefix(token, "Nostr ") {
		return nil, http.StatusUnauthorized, "missing \"Authorization\" header"
	}
	raw, err := base64.StdEncoding.DecodeString(token[6:])
	if err != nil {
		return nil, http.StatusBadRequest, "invalid base64 token"
	}
	var ev nostr.Event
	if err := json.Unmarshal(raw, &ev); err != nil {
		return nil, http.StatusBadRequest, "broken event"
	}
	if ev.Kind != 24242 {
		return nil, http.StatusForbidden, "invalid event"
	}
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return nil, http.StatusForbidden, "only media signed by whitelisted pubkeys are allowed"
	}
	if authExpiration(&ev) <= time.Now().Unix() {
		return nil, http.StatusForbidden, "authorization expired"
	}
	if ev.Tags.FindWithValue("t", "upload") == nil {
		return nil, http.StatusForbidden, "authorization is not for upload"
	}
	if !ev.CheckID() {
		return nil, http.StatusForbidden, "invalid event"
	}
	if ok, _ := ev.CheckSignature(); !ok {
		return nil, http.StatusForbidden, "invalid signature"
	}
	return &ev, 0, ""
}

func authExpiration(ev *nostr.Event) int64 {
	tag := ev.Tags.Find("expiration")
	if tag == nil {
		return 0
	}
	exp, _ := strconv.ParseInt(tag[1], 10, 64)
	return exp
}

// Blossom auth is one per upload: an auth event that already put a blob
// here is refused, until it would have expired anyway.
var (
	meshAuthMu   sync.Mutex
	meshAuthSeen = map[string]int64{} // event id -> expiration
)

// meshAuthUse records ev as used; false if it already was.
func meshAuthUse(ev *nostr.Event) bool {
	meshAuthMu.Lock()
	defer meshAuthMu.Unlock()
	now := time.Now().Unix()
	for id, exp := range meshAuthSeen {
		if exp <= now {
			delete(meshAuthSeen, id)
		}
	}
	if _, used := meshAuthSeen[ev.ID]; used {
		return false
	}
	meshAuthSeen[ev.ID] = authExpiration(ev)
	return true
}

// readMeshBody reads a PUT body of exactly Content-Length bytes into 1 MB
// chunks (no doubling copies) and hashes it on the way. Each read must make
// progress within meshIdleRead, the average must stay above meshMinRate
// after meshRateGrace, all inside the overall transfer deadline.
func readMeshBody(w http.ResponseWriter, r *http.Request) (io.ReadCloser, string, error) {
	rc := http.NewResponseController(w)
	start := time.Now()
	end := start.Add(meshTransferTimeout)
	_ = rc.SetWriteDeadline(end)
	limited := io.LimitReader(r.Body, r.ContentLength+1)
	h := sha256.New()
	var chunks [][]byte
	var got int64
	for {
		next := time.Now().Add(meshIdleRead)
		if next.After(end) {
			next = end
		}
		_ = rc.SetReadDeadline(next)
		if len(chunks) == 0 || len(chunks[len(chunks)-1]) == cap(chunks[len(chunks)-1]) {
			chunks = append(chunks, make([]byte, 0, min(r.ContentLength-got+1, 1<<20)))
		}
		last := chunks[len(chunks)-1]
		n, err := limited.Read(last[len(last):cap(last)])
		chunks[len(chunks)-1] = last[:len(last)+n]
		h.Write(last[len(last) : len(last)+n])
		got += int64(n)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, "", err
		}
		if elapsed := time.Since(start); elapsed > meshRateGrace &&
			float64(got) < meshMinRate*(elapsed-meshRateGrace).Seconds() {
			return nil, "", errors.New("upload too slow")
		}
	}
	if got != r.ContentLength {
		return nil, "", errors.New("length does not match Content-Length")
	}
	return &chunkReader{chunks: chunks}, hex.EncodeToString(h.Sum(nil)), nil
}

// chunkReader hands the chunks to khatru and drops each once read, so the
// door's copy shrinks while khatru's grows.
type chunkReader struct{ chunks [][]byte }

func (c *chunkReader) Read(p []byte) (int, error) {
	for len(c.chunks) > 0 && len(c.chunks[0]) == 0 {
		c.chunks[0] = nil
		c.chunks = c.chunks[1:]
	}
	if len(c.chunks) == 0 {
		return 0, io.EOF
	}
	n := copy(p, c.chunks[0])
	c.chunks[0] = c.chunks[0][n:]
	if len(c.chunks[0]) == 0 && len(c.chunks) == 1 {
		// EOF with the last bytes: khatru grows its full-size buffer when
		// a read fills it and EOF only comes on the next call.
		c.chunks = nil
		return n, io.EOF
	}
	return n, nil
}

func (c *chunkReader) Close() error { c.chunks = nil; return nil }

// meshListener caps the mesh port at meshMaxConns connections at once (every
// peer is 127.0.0.1, so only a global cap means anything) and closes any
// connection, websockets included, after meshConnMaxLifetime.
type meshListener struct {
	net.Listener
	slots chan struct{}
}

func newMeshListener(ln net.Listener) net.Listener {
	return &meshListener{Listener: ln, slots: make(chan struct{}, meshMaxConns)}
}

func (l *meshListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			mc := &meshConn{Conn: c, release: func() { <-l.slots }}
			mc.timer = time.AfterFunc(meshConnMaxLifetime, func() { mc.Close() })
			return mc, nil
		default:
			c.Close() // full: refuse now rather than queue
		}
	}
}

type meshConn struct {
	net.Conn
	release func()
	timer   *time.Timer
	once    sync.Once
}

func (c *meshConn) Close() error {
	c.once.Do(func() {
		c.timer.Stop()
		c.release()
	})
	return c.Conn.Close()
}

func markMesh(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), meshPeerKey{}, true))
}

// meshOwnerEventsOnly: over the mesh, the outbox stores only events the
// owner (or a whitelisted account) signed. An AUTHed session does not widen
// it to other people's events the way MustBeWhitelistedToPost does.
func meshOwnerEventsOnly(ctx context.Context, event *nostr.Event) (bool, string) {
	if !isMeshConn(ctx) {
		return false, ""
	}
	if _, ok := config.WhitelistedPubKeys[event.PubKey]; ok {
		return false, ""
	}
	return true, "restricted: the mesh accepts only the owner's own events"
}

// meshNoQueries: a mesh websocket is for sending. Reading the vault over the
// mesh is blob GET only.
func meshNoQueries(ctx context.Context, _ nostr.Filter) (bool, string) {
	if isMeshConn(ctx) {
		return true, "restricted: no queries over the mesh"
	}
	return false, ""
}

// meshAwareConnectionLimiter is bypassLocalhostConnectionLimiter except for
// mesh connections, which always face the limiter.
func meshAwareConnectionLimiter(inner func(r *http.Request) bool) func(r *http.Request) bool {
	local := bypassLocalhostConnectionLimiter(inner)
	return func(r *http.Request) bool {
		if isMeshRequest(r) {
			return inner(r)
		}
		return local(r)
	}
}
