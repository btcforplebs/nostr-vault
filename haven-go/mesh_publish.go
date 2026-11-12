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
//   - OK true means the vault stored the note and queued its blast;
//   - every other answer is OK false, so the phone sends the note itself:
//     not the owner's, too old (meshPublishMaxAge), ephemeral, already held
//     ("duplicate:"), or a replaceable the vault keeps a newer copy of.
//
// Everything else on the mesh is unchanged (mesh_safety.go): a stranger, a
// connection without the token, or a second-hand write (?pulled=1, the
// own-device port without the token) is stored and never blasted. An old
// note is never re-blasted, even for a paired device.

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// meshPublishVerb is the device token's t for a publish connection.
const meshPublishVerb = "publish"

// meshPublishMaxAge: how old a note may be for the vault to send it. A
// phone hands over what it just signed and waits about 10 s; anything older
// is not "fresh" and is never blasted on a device's behalf.
var meshPublishMaxAge = 5 * time.Minute

var (
	errPublishDup   = errors.New("duplicate: the vault already holds this note and did not send it")
	errPublishStale = errors.New("blocked: the vault keeps a newer copy and did not send this one")
)

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
// stranger or a catch-up, did not have it blasted).
func refuseDupForPublish(store func(context.Context, *nostr.Event) error) func(context.Context, *nostr.Event) error {
	return func(ctx context.Context, ev *nostr.Event) error {
		err := store(ctx, ev)
		if errors.Is(err, eventstore.ErrDupEvent) && isPublishForMeConn(ctx) {
			return errPublishDup
		}
		return err
	}
}

// publishForMe is blastStored for a publish connection: blast what the store
// now holds, and refuse (OK false) a replaceable it did not take.
func publishForMe(ctx context.Context, ev *nostr.Event, stored func(context.Context, string) bool, send func(*nostr.Event)) error {
	if !stored(ctx, ev.ID) {
		slog.Info("publish for a device: a newer copy is kept, not blasted", "id", ev.ID, "kind", ev.Kind)
		return errPublishStale
	}
	slog.Info("event stored, blasted for a paired device", "id", ev.ID, "kind", ev.Kind)
	send(ev)
	return nil
}
