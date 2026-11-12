package main

// Publish for me (sync pick 1, Logen 2026-11-12): the vault sends the
// phone's posts. Exactly one device blasts each note: the vault when it
// confirms within about 10 s, otherwise the phone itself.
//
// A paired device opens the outbox websocket over the mesh (the door, the
// iPhone's own port, or the relay port from loopback) with its own mesh
// key's kind 24242 in the Authorization header: t=publish, a p naming this
// vault's mesh key, at most five minutes ahead, used once
// (withMeshDeviceAuth). Never the account key on the mesh.
//
// On that connection, and only there:
//   - the first frame is ["NOTICE", meshPublishNotice]; a phone that does
//     not see it (an older vault) sends its notes itself;
//   - OK true means the vault stored the note, kept it in the blast queue
//     on disk, and queued its blast;
//   - every other answer is OK false, so the phone sends the note itself:
//     not the owner's, too old (meshPublishMaxAge), ephemeral, already held
//     ("duplicate:"), a replaceable the vault keeps a newer copy of, or no
//     relays to send to.
//
// Everything else on the mesh is unchanged (mesh_safety.go): a stranger, a
// connection without the token, or a second-hand write (?pulled=1, the
// own-device port without the token) is stored and never blasted. An old
// note is never re-blasted, even for a paired device.

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// meshPublishVerb is the device token's t for a publish connection.
const meshPublishVerb = "publish"

// meshPublishNotice is a publish connection's first frame
// (["NOTICE", meshPublishNotice]). A phone counts a confirm only after it:
// an older vault, or one that has not paired the phone, never sends it.
const meshPublishNotice = "publish-for-me: on"

// meshPublishMaxAge: how old a note may be for the vault to send it. A
// phone hands over what it just signed and waits about 10 s; anything older
// is not "fresh" and is never blasted on a device's behalf.
var meshPublishMaxAge = 5 * time.Minute

var (
	errPublishDup      = errors.New("duplicate: the vault already holds this note and did not send it")
	errPublishStale    = errors.New("blocked: the vault keeps a newer copy and did not send this one")
	errPublishNoRelays = errors.New("blocked: the vault has no relays to send to")
	errPublishNotKept  = errors.New("blocked: the vault could not keep the note to send it")
)

// publishForMeKeep puts a note in the blast queue on disk before the vault
// confirms it (init.go sets blastQueue.keepForPublish). Nil: the vault never
// confirms, since nothing would keep the note through a crash.
var publishForMeKeep func(*nostr.Event) bool

// isPublishForMeConn: ctx's connection was admitted on a paired device's
// publish token, the device is still paired, and it is not a second-hand
// writer (?pulled=1 wins: stored, never blasted).
func isPublishForMeConn(ctx context.Context) bool {
	conn := khatru.GetConnection(ctx)
	if conn == nil || conn.Request == nil || isPulledConn(ctx) {
		return false
	}
	dev := meshDeviceAuthIn(conn.Request.Context())
	if dev == nil || !meshDevices.paired(dev.PubKey) {
		return false
	}
	ts := tagValues(dev.Tags, "t")
	return len(ts) == 1 && ts[0] == meshPublishVerb
}

// freshForPublish: ev was signed within meshPublishMaxAge of now (the
// future is refused earlier, by PreventTimestampsInTheFuture).
func freshForPublish(ev *nostr.Event, now time.Time) bool {
	return ev.CreatedAt.Time().After(now.Add(-meshPublishMaxAge))
}

// rejectForPublishForMe is the outbox's RejectEvent for a publish
// connection: what the vault will not send is refused before it is stored,
// so the phone sends it itself.
func rejectForPublishForMe(ctx context.Context, ev *nostr.Event) (bool, string) {
	if !isPublishForMeConn(ctx) {
		return false, ""
	}
	if _, ok := whitelist()[ev.PubKey]; !ok {
		return true, "restricted: the vault sends only the owner's own notes"
	}
	if nostr.IsEphemeralKind(ev.Kind) {
		return true, "blocked: the vault does not send ephemeral events"
	}
	if !freshForPublish(ev, time.Now()) {
		return true, "blocked: too old for the vault to send; send it yourself"
	}
	return false, ""
}

// refuseDupForPublish wraps a store step: on a publish connection, an event
// the store already holds is not confirmed (whoever wrote it first, a
// stranger or a catch-up, did not have it blasted), unless the vault itself
// is already sending it (ownBlasts). Then the answer is the plain OK true
// (ErrDupEvent: khatru says OK and stops, no second blast), so the phone
// does not fan it out too.
func refuseDupForPublish(store func(context.Context, *nostr.Event) error) func(context.Context, *nostr.Event) error {
	return func(ctx context.Context, ev *nostr.Event) error {
		err := store(ctx, ev)
		if errors.Is(err, eventstore.ErrDupEvent) && isPublishForMeConn(ctx) {
			if ownBlasts.has(ev.ID, time.Now()) {
				slog.Info("publish for a device: already sent by the vault, confirmed", "id", ev.ID, "kind", ev.Kind)
				return eventstore.ErrDupEvent
			}
			return errPublishDup
		}
		return err
	}
}

// ownBlasts holds the notes the vault blasted as first-hand owner writes in
// the last meshPublishMaxAge (newBlastStored). The phone sends to the
// author's own 10002 relays at once, alongside the hand-off; when that list
// names this vault's public relay, the copy arriving there is blasted, and
// the hand-off then finds it held (Tron's PR 1970 re-check, Logen's go
// 2026-11-12). The vault is sending it, so it confirms, and exactly one
// device blasts it. Only ids, kept in memory: a note the vault holds but
// did not send (mesh, ?pulled=1) is never here.
var ownBlasts = &recentIDs{}

type recentIDs struct {
	mu  sync.Mutex
	ids map[string]time.Time
}

// add records id as sent at now, dropping entries older than
// meshPublishMaxAge.
func (r *recentIDs) add(id string, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ids == nil {
		r.ids = map[string]time.Time{}
	}
	for k, at := range r.ids {
		if now.Sub(at) > meshPublishMaxAge {
			delete(r.ids, k)
		}
	}
	r.ids[id] = now
}

func (r *recentIDs) has(id string, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	at, ok := r.ids[id]
	return ok && now.Sub(at) <= meshPublishMaxAge
}

// publishForMe is blastStored for a publish connection: blast what the store
// now holds, and refuse (OK false) a replaceable it did not take.
func publishForMe(ctx context.Context, ev *nostr.Event, stored func(context.Context, string) bool, send func(*nostr.Event)) error {
	if !stored(ctx, ev.ID) {
		slog.Info("publish for a device: a newer copy is kept, not blasted", "id", ev.ID, "kind", ev.Kind)
		return errPublishStale
	}
	// Confirm only what will go out: relays to send to, and the note on
	// disk first (Tron, PR 1970 M2: the phone stands down on this OK).
	if len(config.BlastrRelays) == 0 {
		return errPublishNoRelays
	}
	if publishForMeKeep == nil || !publishForMeKeep(ev) {
		return errPublishNotKept
	}
	slog.Info("event stored, blasted for a paired device", "id", ev.ID, "kind", ev.Kind)
	send(ev)
	return nil
}

// announcePublishForMe is the outbox's OnConnect: a publish connection's
// first frame is the publish NOTICE, sent before any EVENT is read.
func announcePublishForMe(ctx context.Context) {
	if !isPublishForMeConn(ctx) {
		return
	}
	if ws := khatru.GetConnection(ctx); ws != nil {
		_ = ws.WriteJSON(nostr.NoticeEnvelope(meshPublishNotice))
	}
}
