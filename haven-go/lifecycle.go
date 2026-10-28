package main

import (
	"context"
	"crypto/tls"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/runsafe"
)

// This file serializes the embedded relay's lifecycle for C-shared hosts
// (macOS/iOS Swift, Android JNI). Hosts historically could overlap
// StartRelayC with a still-running StopRelayC (e.g. a host-side stop
// timeout firing early), which raced the package globals: the in-flight
// stop cancelled the NEW cycle's context and closed the NEWLY opened
// databases, producing writes-to-closed-BadgerDB panics and concurrent
// map faults that killed the host app. All transitions now hold a single
// mutex, and every background goroutine registers with the cycle's
// WaitGroup so teardown can wait for them before closing databases.
//
// The standalone CLI (main.go) keeps its process-lifetime model and does
// not use this.

// relayCycle holds all per-start state. A new instance is created on
// every start and torn down exactly once by stop. Exported funcs snapshot
// it via relayLC.current so they never observe half-initialized state.
type relayCycle struct {
	ctx    context.Context
	cancel context.CancelFunc
	server *http.Server // nil in import mode
	// meshServer is the loopback port the FIPS mesh tunnel forwards to:
	// plain HTTP, blob reads plus owner-signed uploads and events (meshHandler).
	meshServer *http.Server
	// ownServer is the relay in full, plain HTTP on a loopback port, for the
	// owner's own devices on the FIPS mesh. Only iOS sets it: there the relay
	// port is TLS (App Transport Security), and the mesh splices plain HTTP.
	ownServer *http.Server
	pool      *nostr.SimplePool
	wg        sync.WaitGroup

	// running counts live spawned goroutines by name, for the log line
	// when a stop has to leave some behind.
	runningMu sync.Mutex
	running   map[string]int

	// hijacked holds connections the HTTP servers handed over to a
	// handler (khatru's WebSockets). Server.Shutdown neither closes nor
	// waits for them, so their goroutines outlived the cycle and kept
	// querying databases the stop had closed.
	hijackedMu sync.Mutex
	hijacked   map[net.Conn]struct{}
}

type cycleCtxKey struct{}

// newRelayCycle makes a cycle whose context carries the cycle itself, so
// code deep inside a spawned goroutine can register its own helpers with
// spawnFromCtx.
func newRelayCycle() *relayCycle {
	ctx, cancel := context.WithCancel(context.Background())
	c := &relayCycle{cancel: cancel}
	c.ctx = context.WithValue(ctx, cycleCtxKey{}, c)
	return c
}

// spawnFromCtx runs fn on the cycle that ctx belongs to, so teardown waits
// for it; with no cycle in ctx (CLI, tests) it is a plain goroutine. Call
// it only from a goroutine that is itself spawned on that cycle.
func spawnFromCtx(ctx context.Context, name string, fn func()) {
	if c, ok := ctx.Value(cycleCtxKey{}).(*relayCycle); ok {
		c.spawn(name, fn)
		return
	}
	go runsafe.Run(name, fn)
}

// trackHijacked makes srv report the connections it hands to handlers, so
// stop can close them. Serve srv on a listener from trackConns so each
// connection leaves the set again when it closes; otherwise a long-running
// relay keeps every WebSocket it ever accepted until the next stop.
func (c *relayCycle) trackHijacked(srv *http.Server) {
	srv.ConnState = func(conn net.Conn, state http.ConnState) {
		if state != http.StateHijacked {
			return
		}
		if tc, ok := conn.(*tls.Conn); ok {
			conn = tc.NetConn()
		}
		c.hijackedMu.Lock()
		if c.hijacked == nil {
			c.hijacked = map[net.Conn]struct{}{}
		}
		c.hijacked[conn] = struct{}{}
		c.hijackedMu.Unlock()
	}
}

// trackConns wraps ln so a hijacked connection drops out of the cycle's
// set when it closes.
func (c *relayCycle) trackConns(ln net.Listener) net.Listener {
	return &trackedListener{Listener: ln, cycle: c}
}

type trackedListener struct {
	net.Listener
	cycle *relayCycle
}

func (l *trackedListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &trackedConn{Conn: conn, cycle: l.cycle}, nil
}

type trackedConn struct {
	net.Conn
	cycle *relayCycle
}

func (t *trackedConn) Close() error {
	t.cycle.hijackedMu.Lock()
	delete(t.cycle.hijacked, t)
	t.cycle.hijackedMu.Unlock()
	return t.Conn.Close()
}

// closeHijacked closes every handed-over connection. khatru's read loop
// then fails, cancels the connection's context, and its request
// goroutines wind down.
func (c *relayCycle) closeHijacked() int {
	c.hijackedMu.Lock()
	conns := c.hijacked
	c.hijacked = nil
	c.hijackedMu.Unlock()
	for conn := range conns {
		conn.Close()
	}
	return len(conns)
}

// stillRunning names the spawned goroutines that have not returned.
func (c *relayCycle) stillRunning() []string {
	c.runningMu.Lock()
	defer c.runningMu.Unlock()
	names := make([]string, 0, len(c.running))
	for name, n := range c.running {
		if n > 1 {
			name += "×" + strconv.Itoa(n)
		}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// meshWanted is the host's last SetMeshServingC, kept across relay restarts.
var meshWanted atomic.Bool

// setMeshServing opens or closes the live cycle's mesh port. With no relay
// running it only records the wish; the next start honours it.
func setMeshServing(on bool) {
	meshWanted.Store(on)
	relayLC.mu.Lock()
	defer relayLC.mu.Unlock()
	c := relayLC.current.Load()
	if c == nil {
		return
	}
	if on {
		c.startMeshServer()
	} else {
		c.stopMeshServer()
	}
}

// startMeshServer listens on HAVEN_MESH_PLAIN_PORT (loopback, meshHandler),
// the port the FIPS mesh tunnel forwards to. Caller holds relayLC.mu
// or is inside startCycle's setup.
func (c *relayCycle) startMeshServer() {
	if c.meshServer != nil || c.server == nil {
		return
	}
	port, err := strconv.Atoi(os.Getenv("HAVEN_MESH_PLAIN_PORT"))
	if err != nil || port <= 0 {
		log.Println("⚠️ mesh sharing asked for, but HAVEN_MESH_PLAIN_PORT is not set")
		return
	}
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("🚫 mesh port %s: %v", addr, err)
		return
	}
	srv := newMeshServer(addr)
	c.trackHijacked(srv)
	c.meshServer = srv
	c.spawn("mesh-http-server", func() {
		if err := srv.Serve(c.trackConns(newMeshListener(ln))); err != nil && err != http.ErrServerClosed {
			log.Printf("🚫 mesh HTTP server exited: %v", err)
		}
	})
	log.Printf("🔗 mesh listening at http://%s", addr)
	c.startOwnServer()
}

// startOwnServer listens on HAVEN_MESH_OWN_PORT (loopback, plain HTTP, the
// relay's full handler) while sharing: what the mesh hands the owner's own
// devices. Unset on Mac and Android, whose relay port is already plain.
// A plaintext request to the TLS relay port gets Go's 400 "Client sent an
// HTTP request to an HTTPS server", which a sender reads as a refusal.
func (c *relayCycle) startOwnServer() {
	if c.ownServer != nil || c.server == nil {
		return
	}
	raw := os.Getenv("HAVEN_MESH_OWN_PORT")
	if raw == "" {
		return
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port <= 0 {
		log.Printf("⚠️ HAVEN_MESH_OWN_PORT %q is not a port", raw)
		return
	}
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("🚫 mesh own-devices port %s: %v", addr, err)
		return
	}
	srv := &http.Server{Addr: addr, Handler: c.server.Handler}
	c.trackHijacked(srv)
	c.ownServer = srv
	c.spawn("mesh-own-http-server", func() {
		if err := srv.Serve(c.trackConns(ln)); err != nil && err != http.ErrServerClosed {
			log.Printf("🚫 mesh own-devices HTTP server exited: %v", err)
		}
	})
	log.Printf("🔗 mesh own devices listening at http://%s", addr)
}

// stopMeshServer closes the mesh port, cutting reads in progress.
func (c *relayCycle) stopMeshServer() {
	if c.meshServer == nil {
		return
	}
	c.meshServer.Close()
	c.meshServer = nil
	log.Println("🔗 mesh port closed")
	if c.ownServer != nil {
		c.ownServer.Close()
		c.ownServer = nil
		log.Println("🔗 mesh own-devices port closed")
	}
}

// spawn runs fn on a goroutine registered with the cycle's WaitGroup and
// panic-isolated via runsafe. Nested spawn calls are safe as long as the
// spawning goroutine itself was spawned (the counter is then ≥ 1).
func (c *relayCycle) spawn(name string, fn func()) {
	c.wg.Add(1)
	c.runningMu.Lock()
	if c.running == nil {
		c.running = map[string]int{}
	}
	c.running[name]++
	c.runningMu.Unlock()
	go func() {
		defer c.wg.Done()
		defer func() {
			c.runningMu.Lock()
			if c.running[name]--; c.running[name] <= 0 {
				delete(c.running, name)
			}
			c.runningMu.Unlock()
		}()
		runsafe.Run(name, fn)
	}()
}

// waitBackground waits for all spawned goroutines, bounded by d.
// Returns false on timeout.
func (c *relayCycle) waitBackground(d time.Duration) bool {
	done := make(chan struct{})
	go func() { c.wg.Wait(); close(done) }()
	select {
	case <-done:
		return true
	case <-time.After(d):
		return false
	}
}

// lifecycleManager serializes start/stop/backup/restore transitions.
// current is an atomic pointer so read-only exported funcs (e.g.
// ComputePopularNotesC) can snapshot the live cycle without taking the
// mutex.
type lifecycleManager struct {
	mu      sync.Mutex
	current atomic.Pointer[relayCycle]
	// drained is closed once the last stopped cycle's goroutines have all
	// returned and its databases have really closed. Guarded by mu.
	drained <-chan struct{}
}

var relayLC lifecycleManager

var errAlreadyRunning = errors.New("relay already running")

var errStillDraining = errors.New("the last relay cycle is still shutting down")

// drainWait bounds how long a start waits for the last cycle to drain.
var drainWait = 10 * time.Second

// setDrained records when the cycle being torn down will be fully gone.
// Caller holds mu.
func (l *lifecycleManager) setDrained(ch <-chan struct{}) { l.drained = ch }

// awaitDrained waits, up to d, for the last cycle to be fully gone. No new
// cycle, import, backup or restore may open the databases or touch the
// relay globals before then: the old cycle's goroutines would run on top
// of the new one. Caller holds mu.
func (l *lifecycleManager) awaitDrained(d time.Duration) bool {
	if l.drained == nil {
		return true
	}
	select {
	case <-l.drained:
		l.drained = nil
		return true
	case <-time.After(d):
		return false
	}
}

// startCycle runs setup under the lifecycle mutex and installs the cycle
// on success. setup receives the fresh cycle (ctx/cancel populated) and
// must place server/pool on it and spawn goroutines via cycle.spawn.
func (l *lifecycleManager) startCycle(setup func(c *relayCycle) error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.current.Load() != nil {
		return errAlreadyRunning
	}
	if !l.awaitDrained(drainWait) {
		return errStillDraining
	}
	c := newRelayCycle()
	if err := setup(c); err != nil {
		c.cancel()
		c.waitBackground(5 * time.Second) // drain anything setup spawned
		return err
	}
	l.current.Store(c)
	return nil
}

// stopCycle tears down the live cycle, if any. Phase 1 cancels WITHOUT
// the lock so an in-flight import (which holds the lock for its whole
// duration) unblocks; phase 2 acquires the lock and performs the full
// teardown exactly once. Stopping an already-stopped relay is a no-op.
func (l *lifecycleManager) stopCycle(teardown func(c *relayCycle)) {
	if c := l.current.Load(); c != nil {
		c.cancel()
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	c := l.current.Swap(nil)
	if c == nil {
		return
	}
	c.cancel() // idempotent; covers a cycle installed between the phases
	teardown(c)
}

// withExclusiveDBs serializes operations that re-initialize and close the
// databases themselves (backup/restore). Hosts are expected to stop the
// relay first; this enforces it — an operation queued behind an in-flight
// stop waits for it, and one issued against a running relay is refused
// instead of racing the live cycle's databases and config.
func withExclusiveDBs(name string, fn func() int) int {
	relayLC.mu.Lock()
	defer relayLC.mu.Unlock()
	if relayLC.current.Load() != nil {
		log.Printf("🚫 %s refused: relay is running — stop it first", name)
		return 1
	}
	if !relayLC.awaitDrained(drainWait) {
		log.Printf("🚫 %s refused: %v", name, errStillDraining)
		return 1
	}
	return fn()
}
