//go:build js && wasm

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"
	"syscall/js"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Browser entry point. Haven runs in a page or a dedicated worker and has no
// socket of its own: the host hands it byte streams (an in-page client, or a
// FIPS TCP stream the page has already owner-gated) and Haven serves each one
// through the same khatru routes and policies as the native builds.
//
//	havenStart(cfg) -> Promise<void>
//	  cfg = { ownerNpub, whitelist?: [npub], blacklist?: [npub],
//	          wot?: [hex], env?: {KEY: value}, storePrefix?: string }
//	  storePrefix names the IndexedDB stores "haven:<prefix>:<route>"
//	             (letters, digits, - and _), e.g. per account.
//	havenConn(id, opts?) -> { write(Uint8Array), onData(cb), onClose(cb), close() }
//	  id         string or number, unique among open streams.
//	  opts.mode  "nip01" (default): NDJSON, one NIP-01 array per "\n" line in
//	             each direction, carried as ws text messages on opts.route.
//	             "raw": the HTTP upgrade and ws frames themselves; owner only.
//	  opts.route mount path for nip01 (default "/").
//	  opts.owner true for the owner's own streams: skips the connection rate
//	             limiter, which is what loopback gets natively.
//	  opts.peer  rate-limit identity (e.g. the remote npub), so reconnects
//	             share one bucket. Defaults to id.
//	havenStop() -> Promise<void>
//
// A refused havenConn returns the same object with an `error` string; its
// onClose fires with that reason.
//
// Only the relay is served. The background jobs main() starts natively
// (inbox/feed sync, WoT crawl, follower ledger, backups) dial out over
// websockets and do not run here; cfg.wot stands in for the WoT.

func main() {
	nostr.InfoLogger = log.New(io.Discard, "", 0)
	js.Global().Set("havenStart", js.FuncOf(jsHavenStart))
	js.Global().Set("havenConn", js.FuncOf(jsHavenConn))
	js.Global().Set("havenStop", js.FuncOf(jsHavenStop))
	select {}
}

func init() {
	// Natively /feed is read-open because only localhost can reach it. Here
	// any stream can name it, so it gets the private route's read rules.
	feedReadPolicy = append(feedReadPolicy,
		policies.NoEmptyFilters, policies.NoComplexFilters,
		policies.MustAuth, MustBeWhitelistedToQuery)

	ownerConn = func(r *http.Request) bool {
		s, ok := r.Context().Value(streamCtxKey{}).(*havenStream)
		return ok && s.owner
	}
}

// ── lifecycle ───────────────────────────────────────────────────────────

type wasmRelay struct {
	cancel  context.CancelFunc
	server  *http.Server
	ln      *pipeListener
	streams map[string]*jsStream
}

var (
	wasmMu  sync.Mutex
	running *wasmRelay
)

func jsHavenStart(_ js.Value, args []js.Value) any {
	var cfg js.Value
	if len(args) > 0 {
		cfg = args[0]
	}
	return promise(func() error { return havenStart(cfg) })
}

func jsHavenStop(js.Value, []js.Value) any {
	return promise(func() error { havenStop(); return nil })
}

func havenStart(cfg js.Value) error {
	wasmMu.Lock()
	defer wasmMu.Unlock()
	if running != nil {
		return errAlreadyRunning
	}
	if cfg.Type() != js.TypeObject {
		return errors.New("havenStart: cfg must be an object")
	}

	if env := cfg.Get("env"); env.Type() == js.TypeObject {
		keys := js.Global().Get("Object").Call("keys", env)
		for i := 0; i < keys.Length(); i++ {
			k := keys.Index(i).String()
			os.Setenv(k, env.Get(k).String())
		}
	}
	// Checked before it is set, so a rejected start doesn't leave a bad prefix behind for the next one.
	prefix := jsString(cfg.Get("storePrefix"))
	if prefix != "" && !storePrefixRe.MatchString(prefix) {
		return fmt.Errorf("havenStart: storePrefix %q may only hold 1 to 64 letters, digits, - and _", prefix)
	}
	storePrefix = prefix
	ownerNpub := jsString(cfg.Get("ownerNpub"))
	if nPubToPubkey("ownerNpub", ownerNpub) == "" {
		return fmt.Errorf("havenStart: ownerNpub %q is not a valid npub", ownerNpub)
	}
	os.Setenv("OWNER_NPUB", ownerNpub)
	if os.Getenv("DB_ENGINE") == "" {
		os.Setenv("DB_ENGINE", "badger") // there is no LMDB here; skip the warning
	}

	config = loadConfig()
	slog.SetLogLoggerLevel(getLogLevelFromConfig())
	whitelist, err := npubSet(cfg.Get("whitelist"), "whitelist")
	if err != nil {
		return err
	}
	for pk := range whitelist {
		config.WhitelistedPubKeys[pk] = struct{}{}
	}
	if config.BlacklistedPubKeys, err = npubSet(cfg.Get("blacklist"), "blacklist"); err != nil {
		return err
	}
	blacklistOverride.Store(nil)

	members := map[string]bool{}
	for pk := range config.WhitelistedPubKeys {
		members[pk] = true
	}
	if list := cfg.Get("wot"); list.Type() == js.TypeObject {
		for i := 0; i < list.Length(); i++ {
			if pk := jsString(list.Index(i)); nostr.IsValidPublicKey(pk) {
				members[pk] = true
			} else {
				return fmt.Errorf("havenStart: wot[%d] %q is not a hex pubkey", i, pk)
			}
		}
	}
	wot.MarkReady(wot.NewCycle(), staticWot(members))

	ctx, cancel := context.WithCancel(context.Background())
	fs = newRootFs()
	if err := fs.MkdirAll(config.BlossomPath, 0755); err != nil {
		cancel()
		return fmt.Errorf("blossom path: %w", err)
	}
	pool = nostr.NewSimplePool(ctx)
	if err := initRelays(ctx); err != nil {
		cancel()
		CloseDBs()
		return err
	}

	ln := newPipeListener()
	server := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// No proxy sits in front of this server, and in raw mode the
			// caller writes these headers itself: khatru would key its rate
			// limiters on whatever address the caller chose.
			r.Header.Del("X-Forwarded-For")
			r.Header.Del("X-Real-Ip")
			dynamicRelayHandler(w, r)
		}),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			if s, ok := c.(*havenStream); ok {
				return context.WithValue(ctx, streamCtxKey{}, s)
			}
			return ctx
		},
	}
	go server.Serve(ln)

	running = &wasmRelay{cancel: cancel, server: server, ln: ln, streams: map[string]*jsStream{}}
	store := "IndexedDB"
	if runningUnderNode() {
		store = "memory (node)"
	}
	log.Printf("🚀 HAVEN %s serving in the browser, store: %s", config.RelayVersion, store)
	return nil
}

func havenStop() {
	wasmMu.Lock()
	r := running
	running = nil
	wasmMu.Unlock()
	if r == nil {
		return
	}
	for _, s := range r.streams {
		s.shutdown("relay stopped")
	}
	r.server.Close()
	r.cancel()
	CloseDBs()
}

type staticWot map[string]bool

func (w staticWot) Has(_ context.Context, pk string) bool { return w[pk] }

// ── streams ─────────────────────────────────────────────────────────────

type streamCtxKey struct{}

// havenStream is the server half of one havenConn. Its RemoteAddr is a
// synthetic host derived from opts.peer (or id), so each caller gets its own
// rate-limit bucket. It never looks like loopback; the owner's streams skip
// the connection limiter by the owner flag instead (ownerConn).
type havenStream struct {
	net.Conn
	addr  pipeAddr
	owner bool
}

func (s *havenStream) RemoteAddr() net.Addr { return s.addr }

type pipeAddr string

func (a pipeAddr) Network() string { return "haven" }
func (a pipeAddr) String() string  { return string(a) }

func streamAddr(key string) pipeAddr {
	sum := sha256.Sum256([]byte(key))
	return pipeAddr("c" + hex.EncodeToString(sum[:8]) + ":0")
}

// pipeListener feeds havenConn's server halves to http.Server.
type pipeListener struct {
	ch   chan net.Conn
	done chan struct{}
	once sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{ch: make(chan net.Conn), done: make(chan struct{})}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.ch:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *pipeListener) Addr() net.Addr { return pipeAddr("haven:0") }

func (l *pipeListener) deliver(c net.Conn) bool {
	select {
	case l.ch <- c:
		return true
	case <-l.done:
		return false
	}
}

// jsStream is the JS-facing half. JS callbacks never block: write only
// queues, and one goroutine per direction moves the bytes. Data for JS is
// queued too and handed over in order by a single deliverer, so nothing
// arrives out of order or before onData is registered.
type jsStream struct {
	id    string
	nip01 bool

	mu       sync.Mutex
	in       [][]byte // to Haven: whole lines (nip01) or chunks (raw)
	inBytes  int      // bytes in `in`, for buffered()
	partial  []byte   // nip01: an unterminated line across writes
	out      [][]byte // to JS
	onData   js.Value
	onClose  js.Value
	reason   string
	closed   bool
	notified bool

	inWake  chan struct{}
	outWake chan struct{}
	done    chan struct{}
	closeIO func()
}

func newJSStream(id string, nip01 bool) *jsStream {
	return &jsStream{
		id: id, nip01: nip01,
		onData: js.Undefined(), onClose: js.Undefined(),
		inWake: make(chan struct{}, 1), outWake: make(chan struct{}, 1),
		done: make(chan struct{}), closeIO: func() {},
	}
}

func wake(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

// maxLineIn caps one unterminated nip01 line, as the native ws path does
// below its own reassembly. Over it, the stream is closed: the bytes never
// reach Haven and the partial buffer cannot grow without limit.
const maxLineIn = 512_000

func (s *jsStream) write(b []byte) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	if !s.nip01 {
		s.in = append(s.in, b)
		s.inBytes += len(b)
	} else {
		for len(b) > 0 {
			i := indexByte(b, '\n')
			if i < 0 {
				if len(s.partial)+len(b) > maxLineIn {
					s.mu.Unlock()
					s.shutdown("line too long")
					return
				}
				s.partial = append(s.partial, b...)
				break
			}
			if len(s.partial)+i > maxLineIn {
				s.mu.Unlock()
				s.shutdown("line too long")
				return
			}
			line := append(s.partial, b[:i]...)
			s.partial = nil
			b = b[i+1:]
			if n := len(line); n > 0 && line[n-1] == '\r' {
				line = line[:n-1]
			}
			if len(line) > 0 {
				s.in = append(s.in, line)
				s.inBytes += len(line)
			}
		}
	}
	s.mu.Unlock()
	wake(s.inWake)
}

// buffered is the bytes written but not yet handed to Haven, so the host can
// stop reading while Haven is behind.
func (s *jsStream) buffered() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.inBytes + len(s.partial)
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// pump sends queued input to Haven until the stream closes.
func (s *jsStream) pump(send func([]byte) error) {
	for {
		select {
		case <-s.inWake:
		case <-s.done:
			return
		}
		s.mu.Lock()
		batch := s.in
		s.in = nil
		s.mu.Unlock()
		for _, b := range batch {
			if err := send(b); err != nil {
				s.shutdown(err.Error())
				return
			}
			s.mu.Lock()
			if !s.closed {
				s.inBytes -= len(b)
			}
			s.mu.Unlock()
		}
	}
}

func (s *jsStream) emit(b []byte) {
	s.mu.Lock()
	s.out = append(s.out, b)
	s.mu.Unlock()
	wake(s.outWake)
}

// deliver hands queued output to onData, then fires onClose once the stream
// is closed and everything before the close has been handed over.
func (s *jsStream) deliver() {
	for range s.outWake {
		s.mu.Lock()
		cb := s.onData
		var batch [][]byte
		if cb.Type() == js.TypeFunction {
			batch, s.out = s.out, nil
		}
		fire := s.closed && len(s.out) == 0 && !s.notified && s.onClose.Type() == js.TypeFunction
		if fire {
			s.notified = true
		}
		closeCb, reason := s.onClose, s.reason
		s.mu.Unlock()

		for _, b := range batch {
			u8 := js.Global().Get("Uint8Array").New(len(b))
			js.CopyBytesToJS(u8, b)
			s.call("onData", cb, u8)
		}
		if fire {
			s.call("onClose", closeCb, reason)
			return
		}
	}
}

// call invokes a host callback. A throwing callback is the host's bug, but
// syscall/js turns it into a Go panic that would take the whole relay down,
// so it is logged and the stream carries on.
func (s *jsStream) call(name string, cb js.Value, arg any) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("⚠️ havenConn %q: %s callback threw: %v", s.id, name, r)
		}
	}()
	cb.Invoke(arg)
}

func (s *jsStream) shutdown(reason string) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.reason = reason
	s.in = nil
	s.inBytes = 0
	s.partial = nil
	closeIO := s.closeIO
	s.mu.Unlock()

	close(s.done)
	closeIO()
	wasmMu.Lock()
	if running != nil && running.streams[s.id] == s {
		delete(running.streams, s.id)
	}
	wasmMu.Unlock()
	wake(s.outWake)
}

func (s *jsStream) jsObject(errMsg string) js.Value {
	obj := js.Global().Get("Object").New()
	obj.Set("write", js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 && args[0].Type() == js.TypeObject {
			b := make([]byte, args[0].Get("length").Int())
			js.CopyBytesToGo(b, args[0])
			s.write(b)
		}
		return nil
	}))
	obj.Set("onData", js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 {
			s.mu.Lock()
			s.onData = args[0]
			s.mu.Unlock()
			wake(s.outWake)
		}
		return nil
	}))
	obj.Set("onClose", js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 {
			s.mu.Lock()
			s.onClose = args[0]
			s.mu.Unlock()
			wake(s.outWake)
		}
		return nil
	}))
	obj.Set("buffered", js.FuncOf(func(js.Value, []js.Value) any {
		return s.buffered()
	}))
	obj.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		go s.shutdown("closed")
		return nil
	}))
	if errMsg != "" {
		obj.Set("error", errMsg)
	}
	return obj
}

func jsHavenConn(_ js.Value, args []js.Value) any {
	id := ""
	if len(args) > 0 && (args[0].Type() == js.TypeString || args[0].Type() == js.TypeNumber) {
		id = js.Global().Get("String").Invoke(args[0]).String()
	}
	opts := js.Undefined()
	if len(args) > 1 {
		opts = args[1]
	}
	mode, route := "nip01", "/"
	owner, peer := false, id
	if opts.Type() == js.TypeObject {
		if v := jsString(opts.Get("mode")); v != "" {
			mode = v
		}
		if v := jsString(opts.Get("route")); v != "" {
			route = v
		}
		owner = opts.Get("owner").Truthy()
		if v := jsString(opts.Get("peer")); v != "" {
			peer = v
		}
	}

	s := newJSStream(id, mode == "nip01")
	go s.deliver()
	refuse := func(msg string) any {
		s.shutdown(msg)
		return s.jsObject(msg)
	}
	switch {
	case id == "":
		return refuse("havenConn: id is required")
	case mode != "nip01" && mode != "raw":
		return refuse(fmt.Sprintf("havenConn: unknown mode %q", mode))
	case mode == "raw" && !owner:
		return refuse("havenConn: raw mode is owner-only")
	case len(route) == 0 || route[0] != '/':
		return refuse(fmt.Sprintf("havenConn: route %q must start with /", route))
	}

	wasmMu.Lock()
	r := running
	if r == nil {
		wasmMu.Unlock()
		return refuse("havenConn: relay is not running")
	}
	if _, taken := r.streams[id]; taken {
		wasmMu.Unlock()
		return refuse(fmt.Sprintf("havenConn: id %q is already open", id))
	}
	r.streams[id] = s
	wasmMu.Unlock()

	serverSide, clientSide := net.Pipe()
	s.mu.Lock()
	s.closeIO = func() { clientSide.Close() }
	s.mu.Unlock()
	go func() {
		if !r.ln.deliver(&havenStream{Conn: serverSide, addr: streamAddr(peer), owner: owner}) {
			serverSide.Close()
			s.shutdown("relay stopped")
		}
	}()

	if mode == "raw" {
		go s.pump(func(b []byte) error { _, err := clientSide.Write(b); return err })
		go func() {
			buf := make([]byte, 32<<10)
			for {
				n, err := clientSide.Read(buf)
				if n > 0 {
					s.emit(append([]byte(nil), buf[:n]...))
				}
				if err != nil {
					s.shutdown(readReason(err))
					return
				}
			}
		}()
		return s.jsObject("")
	}

	go func() {
		dialer := websocket.Dialer{
			NetDialContext: func(context.Context, string, string) (net.Conn, error) {
				return clientSide, nil
			},
			HandshakeTimeout: 10 * time.Second,
		}
		ws, resp, err := dialer.Dial("ws://haven"+route, nil)
		if resp != nil && resp.Body != nil {
			resp.Body.Close()
		}
		if err != nil {
			s.shutdown("handshake: " + err.Error())
			return
		}
		s.mu.Lock()
		closed := s.closed
		s.closeIO = func() { ws.Close() }
		s.mu.Unlock()
		if closed {
			ws.Close()
			return
		}
		go s.pump(func(line []byte) error { return ws.WriteMessage(websocket.TextMessage, line) })
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				s.shutdown(readReason(err))
				return
			}
			// khatru ends every message with "\n" already; one line out
			// per message, never an empty one.
			s.emit(append(bytes.TrimRight(msg, "\r\n"), '\n'))
		}
	}()
	return s.jsObject("")
}

func readReason(err error) string {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe) || websocket.IsCloseError(err, websocket.CloseNormalClosure) {
		return "closed"
	}
	return err.Error()
}

// ── helpers ─────────────────────────────────────────────────────────────

func jsString(v js.Value) string {
	if v.Type() == js.TypeString {
		return v.String()
	}
	return ""
}

func npubSet(list js.Value, name string) (map[string]struct{}, error) {
	out := map[string]struct{}{}
	if list.Type() != js.TypeObject {
		return out, nil
	}
	for i := 0; i < list.Length(); i++ {
		npub := jsString(list.Index(i))
		pk := nPubToPubkey(name, npub)
		if pk == "" {
			return nil, fmt.Errorf("havenStart: %s[%d] %q is not a valid npub", name, i, npub)
		}
		out[pk] = struct{}{}
	}
	return out, nil
}

// promise runs fn on a goroutine (it may block: IndexedDB awaits callbacks)
// and settles a JS Promise with its result.
func promise(fn func() error) js.Value {
	executor := js.FuncOf(func(_ js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			if err := fn(); err != nil {
				reject.Invoke(js.Global().Get("Error").New(err.Error()))
				return
			}
			resolve.Invoke()
		}()
		return nil
	})
	defer executor.Release()
	return js.Global().Get("Promise").New(executor)
}
