package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"sync"
	"time"

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
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
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
	authors := make([]string, 0, len(config.WhitelistedPubKeys))
	for pk := range config.WhitelistedPubKeys {
		authors = append(authors, pk)
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
		if _, ok := config.WhitelistedPubKeys[auth.PubKey]; ok {
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
// only when it came from the owner's own side (not the mesh door) and the
// store really holds it now. For replaceable kinds khatru calls this after
// ReplaceEvent, which returns nil when it keeps a newer copy; blasting then
// would push a stale profile, follow list or 10063 back onto public relays.
func newBlastStored(stored func(ctx context.Context, id string) bool, send func(*nostr.Event)) func(context.Context, *nostr.Event) error {
	return func(ctx context.Context, ev *nostr.Event) error {
		if isMeshConn(ctx) {
			slog.Info("event stored from the mesh, not blasted", "id", ev.ID, "kind", ev.Kind)
			return nil
		}
		if !stored(ctx, ev.ID) {
			slog.Info("event not stored (a newer copy is kept), not blasted", "id", ev.ID, "kind", ev.Kind)
			return nil
		}
		slog.Info("event stored")
		send(ev)
		return nil
	}
}

// outboxHolds reports whether the outbox store holds event id.
func outboxHolds(ctx context.Context, id string) bool {
	if outboxDB == nil {
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ch, err := outboxDB.QueryEvents(ctx, nostr.Filter{IDs: []string{id}, Limit: 1})
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
