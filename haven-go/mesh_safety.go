package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// What a stranger on the mesh may read and make the vault do (Tron's review
// of the Mac mesh door, RESEARCH/NV_MAC_MESH_OWNER_SAFETY.md):
//   1. GET/HEAD a blob only when a note in the outbox (what the vault serves
//      publicly anyway) names it. Drive files, private-relay attachments and
//      DM media are not readable by hash.
//   2. Nothing a stranger sends over the mesh is blasted, and nothing the
//      store declined (an older or equal replaceable) is blasted at all.
//   3. A blob response must keep moving, or the reader loses its slot.

// meshBlobIndexTTL: how long the set of publicly named blobs is trusted
// before it is read again from the outbox. Notes stored meanwhile are added
// as they arrive, so the TTL only bounds how long a deleted note's media
// stays readable.
var meshBlobIndexTTL = 2 * time.Minute

// meshBlobPageSize stays under the eventstores' query limit (LMDB serves at
// most 1500; a larger limit is not clamped, it falls back to a small default).
const meshBlobPageSize = 1000

var hex64Re = regexp.MustCompile(`[0-9a-fA-F]{64}`)

// Kinds whose content is not public even in the outbox.
var meshBlobPrivateKinds = map[int]bool{4: true, 13: true, 14: true, 15: true, 1059: true}

type meshBlobIndex struct {
	mu    sync.Mutex
	set   map[string]struct{}
	built time.Time
}

var meshBlobs = &meshBlobIndex{}

// add records the blob hashes ev names, in tags (x, imeta, url…) or content.
func (m *meshBlobIndex) add(ev *nostr.Event) {
	if ev == nil || meshBlobPrivateKinds[ev.Kind] {
		return
	}
	if _, ok := whitelist()[ev.PubKey]; !ok {
		return
	}
	if _, b := broughtAccounts()[ev.PubKey]; b {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.set == nil {
		return // not built yet: the first lookup reads the whole outbox
	}
	addHashes(m.set, ev)
}

func addHashes(set map[string]struct{}, ev *nostr.Event) {
	for _, h := range hex64Re.FindAllString(ev.Content, -1) {
		set[toLower(h)] = struct{}{}
	}
	for _, tag := range ev.Tags {
		for _, v := range tag {
			for _, h := range hex64Re.FindAllString(v, -1) {
				set[toLower(h)] = struct{}{}
			}
		}
	}
}

func toLower(h string) string {
	b := []byte(h)
	for i, c := range b {
		if c >= 'A' && c <= 'F' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// has reports whether a public note in the outbox names sha256.
func (m *meshBlobIndex) has(ctx context.Context, sha256 string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.set == nil || time.Since(m.built) > meshBlobIndexTTL {
		set, err := readPublicBlobRefs(ctx)
		if err != nil {
			slog.Warn("mesh blob index: could not read the outbox", "error", err)
			if m.set == nil {
				return false // fail closed
			}
		} else {
			m.set, m.built = set, time.Now()
		}
	}
	_, ok := m.set[toLower(sha256)]
	return ok
}

func (m *meshBlobIndex) reset() {
	m.mu.Lock()
	m.set = nil
	m.mu.Unlock()
}

// readPublicBlobRefs pages through the whitelisted authors' outbox events.
func readPublicBlobRefs(ctx context.Context) (map[string]struct{}, error) {
	if outboxDB == nil {
		return nil, errors.New("no outbox")
	}
	authors := make([]string, 0, len(whitelist()))
	brought := broughtAccounts()
	for pk := range whitelist() {
		// A brought-over account's photos are never served (Logen, 2026-11-06).
		if _, b := brought[pk]; !b {
			authors = append(authors, pk)
		}
	}
	set := map[string]struct{}{}
	if len(authors) == 0 {
		return set, nil
	}
	var until *nostr.Timestamp
	seen := map[string]struct{}{}
	for {
		ch, err := outboxDB.QueryEvents(ctx, nostr.Filter{Authors: authors, Until: until, Limit: meshBlobPageSize})
		if err != nil {
			return nil, err
		}
		n, fresh := 0, 0
		var oldest nostr.Timestamp
		for ev := range ch {
			n++
			if oldest == 0 || ev.CreatedAt < oldest {
				oldest = ev.CreatedAt
			}
			if _, dup := seen[ev.ID]; dup {
				continue
			}
			seen[ev.ID] = struct{}{}
			fresh++
			if !meshBlobPrivateKinds[ev.Kind] {
				addHashes(set, ev)
			}
		}
		// Done when a page comes back short, or holds nothing new (many
		// events sharing one second straddle a page boundary).
		if n < meshBlobPageSize || fresh == 0 || oldest == 0 {
			return set, nil
		}
		next := oldest
		if until != nil && next >= *until {
			next = *until - 1
		}
		until = &next
	}
}

// meshBlobRejectGet is Blossom's RejectGet: over the mesh, a blob is served
// only when a public note names it, or to the owner's own signed request
// (khatru has already checked that auth's signature, expiry, "get" and hash).
func meshBlobRejectGet(ctx context.Context, auth *nostr.Event, sha256 string, _ string) (bool, string, int) {
	if ctx.Value(meshPeerKey{}) == nil {
		return false, "", 0
	}
	if auth != nil {
		if _, ok := whitelist()[auth.PubKey]; ok {
			return false, "", 0
		}
		if isMeshDeviceAuth(ctx, auth) {
			return false, "", 0
		}
	}
	if meshBlobs.has(ctx, sha256) {
		return false, "", 0
	}
	// 404, the same answer as a blob that is not here: no yes/no oracle.
	return true, "not found", http.StatusNotFound
}

// guardMeshBlobs wires (1) into a Blossom server.
func guardMeshBlobs(bs *blossom.BlossomServer) {
	bs.RejectGet = append(bs.RejectGet, meshBlobRejectGet)
}

// noteStoredForMeshBlobs keeps the index current as notes are stored.
func noteStoredForMeshBlobs(_ context.Context, ev *nostr.Event) error {
	meshBlobs.add(ev)
	return nil
}

// newBlastStored is the outbox's after-store hook for (2): blast an event
// only when it came from the owner's own side (not the mesh door, unless a
// paired device asked the vault to send it: mesh_publish.go) and the
// store really holds it now. For replaceable kinds khatru calls this after
// ReplaceEvent, which returns nil when it keeps a newer copy; blasting then
// would push a stale profile, follow list or 10063 back onto public relays.
func newBlastStored(stored func(ctx context.Context, id string) bool, send func(*nostr.Event)) func(context.Context, *nostr.Event) error {
	return func(ctx context.Context, ev *nostr.Event) error {
		if isPublishForMeConn(ctx) {
			// A paired device asked the vault to send it (mesh_publish.go).
			return publishForMe(ctx, ev, stored, send)
		}
		if isMeshConn(ctx) {
			slog.Info("event stored from the mesh, not blasted", "id", ev.ID, "kind", ev.Kind)
			return nil
		}
		if isSecondHandConn(ctx) {
			slog.Debug("second-hand event stored, not blasted", "id", ev.ID, "kind", ev.Kind)
			return nil
		}
		if !stored(ctx, ev.ID) {
			slog.Info("event not stored (a newer copy is kept), not blasted", "id", ev.ID, "kind", ev.Kind)
			return nil
		}
		slog.Info("event stored")
		if len(config.BlastrRelays) > 0 {
			ownBlasts.add(ev.ID, time.Now())
		}
		send(ev)
		return nil
	}
}

// pulledInjectionParam marks a connection that writes events the app pulled
// from relays (`?pulled=1`: the Apple apps' FeedService and NetworkSyncService
// injection clients). Those are stored and never blasted: they came from the
// relays, and sending each one back to every write relay was the .99 storm
// (Logen's pick, 2026-11-12). Anything else written to the outbox (the apps
// posting, the owner's devices, any client) is blasted as before. A client
// that sets it only keeps its own notes from being blasted; strangers still
// cannot write here (MustBeWhitelistedToPost).
const pulledInjectionParam = "pulled"

// isPulledConn reports whether ctx's connection is a pulled-events writer.
func isPulledConn(ctx context.Context) bool {
	conn := khatru.GetConnection(ctx)
	return conn != nil && conn.Request != nil && conn.Request.URL.Query().Get(pulledInjectionParam) == "1"
}

// isSecondHandConn: ctx's writes are not first-hand, so they are stored and
// never blasted (device sync map §4.5, "only first-hand writes are
// published"). A note is blasted once, by the device it was written on.
//   - `?pulled=1`: pulled from relays (the apps' injection clients), or sent
//     by another of the owner's devices (owner catch-up uploads, the blast
//     to the Mac, HomeVaultSender; ownDeviceWriteURL and the apps mark
//     those).
//   - the iPhone's own-device port (HAVEN_MESH_OWN_PORT): only the owner's
//     other devices reach it.
//
// The mesh door is checked on its own in blastStored.
func isSecondHandConn(ctx context.Context) bool {
	if isPulledConn(ctx) {
		return true
	}
	conn := khatru.GetConnection(ctx)
	return conn != nil && conn.Request != nil && conn.Request.Context().Value(meshOwnPortKey{}) != nil
}

// ownDeviceWriteURL is url marked as second-hand (`?pulled=1`) when it is
// another of the owner's devices' relay (the Mac relay, MAC_RELAY_URL), so
// what this vault sends there is stored and not blasted again. Any other
// relay is dialled as it is.
func ownDeviceWriteURL(raw string) string {
	base := macRelayBase(config.MacRelayURL)
	if base == "" {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	q := u.Query()
	plain := *u
	plain.RawQuery = ""
	if strings.TrimRight(plain.String(), "/") != base {
		return raw
	}
	if q.Get(pulledInjectionParam) == "1" {
		return raw
	}
	q.Set(pulledInjectionParam, "1")
	u.RawQuery = q.Encode()
	return u.String()
}

// wireOutboxWrites adds the outbox store, the mesh blob index and the blast
// (send) to relay's store chains. khatru hands replaceable kinds (0, 3,
// 10002, 10063, 30023…) to ReplaceEvent, never StoreEvent, so they are
// blasted there too: a phone's 10063 sent only to this relay otherwise never
// reaches the public relays.
//
// A copy the outbox already holds is not blasted again. For a regular kind
// the store says so itself (eventstore.ErrDupEvent ends khatru's chain); a
// replaceable kind's ReplaceEvent returned nil for a copy it already had, so
// the chain went on to the blast and every re-sent profile, follow list or
// article went out to every relay again (the .99 blast storm, 2026-11-12).
// replaceOrDup answers ErrDupEvent for those too.
func wireOutboxWrites(relay *khatru.Relay, db DBBackend, send func(*nostr.Event)) {
	blastStored := newBlastStored(outboxHolds, send)
	relay.OnConnect = append(relay.OnConnect, announcePublishForMe)
	relay.RejectEvent = append(relay.RejectEvent, rejectForPublishForMe)
	relay.StoreEvent = append(relay.StoreEvent, refuseDupForPublish(db.SaveEvent), noteStoredForMeshBlobs, blastStored)
	relay.ReplaceEvent = append(relay.ReplaceEvent, refuseDupForPublish(replaceOrDup(db)), noteStoredForMeshBlobs, blastStored)
}

// replaceOrDup is db.ReplaceEvent, except that an event db already holds
// (same id) is eventstore.ErrDupEvent, as SaveEvent answers for a regular
// kind: khatru then says OK and stops the chain. Storing it again would
// change nothing.
func replaceOrDup(db DBBackend) func(context.Context, *nostr.Event) error {
	return func(ctx context.Context, ev *nostr.Event) error {
		if storeHolds(ctx, db, ev.ID) {
			return eventstore.ErrDupEvent
		}
		return db.ReplaceEvent(ctx, ev)
	}
}

// outboxHolds reports whether the outbox store holds event id.
func outboxHolds(ctx context.Context, id string) bool {
	if outboxDB == nil {
		return false
	}
	return storeHolds(ctx, outboxDB, id)
}

// storeHolds reports whether db holds event id.
func storeHolds(ctx context.Context, db DBBackend, id string) bool {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ch, err := db.QueryEvents(ctx, nostr.Filter{IDs: []string{id}, Limit: 1})
	if err != nil {
		return false
	}
	found := false
	for range ch {
		found = true
	}
	return found
}

// (3) A blob response must keep moving: each write gets meshIdleWrite to
// go through, and after meshSendGrace the average must stay above
// meshMinSendRate. A reader that stalls loses its door slot in seconds, not
// at the 30-minute transfer deadline.
var (
	meshIdleWrite   = 15 * time.Second
	meshSendGrace   = 15 * time.Second
	meshMinSendRate = 8.0 * 1024
)

var errMeshReaderTooSlow = errors.New("mesh reader too slow")

type meshSendFloorWriter struct {
	http.ResponseWriter
	rc    *http.ResponseController
	start time.Time
	end   time.Time
	sent  int64
}

func newMeshSendFloorWriter(w http.ResponseWriter) *meshSendFloorWriter {
	now := time.Now()
	return &meshSendFloorWriter{ResponseWriter: w, rc: http.NewResponseController(w), start: now, end: now.Add(meshTransferTimeout)}
}

func (m *meshSendFloorWriter) Write(p []byte) (int, error) {
	if elapsed := time.Since(m.start); elapsed > meshSendGrace &&
		float64(m.sent) < meshMinSendRate*(elapsed-meshSendGrace).Seconds() {
		return 0, errMeshReaderTooSlow
	}
	// Write in pieces so a stalled reader is seen at each idle deadline,
	// not after one large buffer.
	total := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > 32<<10 {
			chunk = chunk[:32<<10]
		}
		next := time.Now().Add(meshIdleWrite)
		if next.After(m.end) {
			next = m.end
		}
		_ = m.rc.SetWriteDeadline(next)
		n, err := m.ResponseWriter.Write(chunk)
		total += n
		m.sent += int64(n)
		if err != nil {
			return total, err
		}
		p = p[n:]
	}
	return total, nil
}

func (m *meshSendFloorWriter) Unwrap() http.ResponseWriter { return m.ResponseWriter }

func (m *meshSendFloorWriter) Flush() {
	_ = m.rc.Flush()
}
