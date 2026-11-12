package main

// /files: the owner's media file notes (NIP-94 kind 1063), so every open
// Media tab hears an upload or delete from any of the owner's devices
// (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md, Logen's go 2026-11-12).
//
//   - Reached over the mesh door and from this machine (loopback, no tunnel
//     or LAN hop named) only: never the public URL, never the outbox, never
//     blasted, never in a backup zip or copy.
//   - Written by this vault's paired devices with their own mesh key, by
//     this vault's own mesh key, or by the vault itself (filesVaultKey). Never
//     the account key or any other whitelisted key (mesh_devices.go: the mesh
//     never uses the account key).
//   - Read by the owner, a paired device or the vault's own mesh key, AUTHed.
//     Not by every whitelisted account (the PR 1971 must-fix).
//   - Trust is checked live: a device that is unpaired can't write, read, or
//     be heard, and its old notes stop being served (kept, in case it pairs
//     again).

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

const (
	filesPath        = "/files"
	kindFileMetadata = 1063
)

var (
	filesRelay *khatru.Relay
	filesDB    DBBackend
)

func initFilesRelay() *khatru.Relay {
	rl := khatru.NewRelay()
	rl.Info.Name = config.PrivateRelayName + " media notes"
	rl.Info.Description = "which of your devices has which media file"
	rl.Info.Version = config.RelayVersion
	rl.Info.Software = config.RelaySoftware
	rl.ServiceURL = relayServiceURL(filesPath)
	serviceURLFromHost(rl, filesPath)
	pinMeshAuthURL(rl, filesPath)

	rl.RejectConnection = append(rl.RejectConnection, filesNotReachable)
	rl.OnConnect = append(rl.OnConnect, khatru.RequestAuth)
	rl.RejectEvent = append(rl.RejectEvent,
		policies.PreventTimestampsInTheFuture(maxFutureSkew),
		rejectFilesWrite,
		rejectFilesDuplicate,
		rejectFilesDeleted,
	)
	rl.RejectFilter = append(rl.RejectFilter, policies.MustAuth, rejectFilesRead)
	rl.RejectCountFilter = append(rl.RejectCountFilter, policies.MustAuth, rejectFilesRead)
	rl.StoreEvent = append(rl.StoreEvent, func(ctx context.Context, ev *nostr.Event) error {
		return filesDB.SaveEvent(ctx, ev)
	})
	rl.DeleteEvent = append(rl.DeleteEvent, func(ctx context.Context, ev *nostr.Event) error {
		return filesDB.DeleteEvent(ctx, ev)
	})
	rl.OverwriteDeletionOutcome = append(rl.OverwriteDeletionOutcome, filesDeletionOutcome)
	rl.QueryEvents = append(rl.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		return queryTrustedFiles(ctx, f)
	})
	rl.CountEvents = append(rl.CountEvents, func(ctx context.Context, f nostr.Filter) (int64, error) {
		ch, err := queryTrustedFiles(ctx, f)
		if err != nil {
			return 0, err
		}
		var n int64
		for range ch {
			n++
		}
		return n, nil
	})
	rl.PreventBroadcast = append(rl.PreventBroadcast, filesPreventBroadcast)
	// The door's caps (limit, filters per REQ, listeners, answer bytes, no
	// negentropy, no COUNT) over the mesh. Last: it wraps QueryEvents.
	wireMeshReadCaps(rl)

	rl.Router().HandleFunc("GET "+filesPath, func(w http.ResponseWriter, r *http.Request) {
		renderFallbackPage(w, rl.Info.Name, rl.Info.Description, getWSScheme(config.RelayURL)+config.RelayURL+filesPath)
	})
	return rl
}

// filesNotReachable: /files is for the owner's own devices, so it is served
// over the mesh and to this machine only (the same rule as a device key on
// Blossom, meshDeviceOverMesh). On the box the relay port is also the public
// URL; there it is refused.
func filesNotReachable(r *http.Request) bool {
	return !meshDeviceOverMesh(r)
}

// filesWriter: pk may write notes here: a paired device, this vault's own
// mesh key, or the vault itself. Checked on every write and every read,
// so an unpaired device stops at once.
func filesWriter(pk string) bool {
	if pk == "" {
		return false
	}
	// An account key never writes here, even if the app's device list names
	// it (as self or a device): the mesh never uses the account key (Tron,
	// #1974). Same order as Blossom's withMeshDeviceAuth.
	if config.OwnerPubKey != "" && pk == config.OwnerPubKey {
		return false
	}
	if _, account := whitelist()[pk]; account {
		return false
	}
	if self := meshDevices.selfKey(); self != "" && pk == self {
		return true
	}
	if pk == filesVaultPubKey() {
		return true
	}
	return meshDevices.paired(pk)
}

// filesStoreLeftOut: the files store never travels: not in a backup zip, not
// in a mesh copy, and not taken from either on import.
func filesStoreLeftOut(name string) bool { return name == "files" }

// filesReader: pk may read /files: the owner, or a key that may write.
// TODO(1971): swap the owner half for its owner-read-set helper.
func filesReader(pk string) bool {
	if pk == "" {
		return false
	}
	if config.OwnerPubKey != "" && pk == config.OwnerPubKey {
		return true
	}
	return filesWriter(pk)
}

// rejectFilesWrite is the whole write gate. It is not MustBeWhitelistedToPost:
// it refuses the account key and every whitelisted key, and takes only the
// owner's devices' own keys.
func rejectFilesWrite(ctx context.Context, ev *nostr.Event) (bool, string) {
	if ev.PubKey == filesVaultPubKey() {
		// Only the vault itself holds this key; it never comes over a socket.
		return true, "restricted: this key is the vault's own"
	}
	if !filesWriter(ev.PubKey) {
		if _, account := whitelist()[ev.PubKey]; account {
			return true, "restricted: media notes are signed with a device's mesh key, never an account key"
		}
		return true, "restricted: only this vault's paired devices write media notes"
	}
	switch ev.Kind {
	case kindFileMetadata:
		return checkFileNote(ev)
	case nostr.KindDeletion:
		return checkFilesDeletion(ev)
	}
	return true, "blocked: this relay takes only file notes (1063) and their deletions (5)"
}

// checkFileNote: a kind 1063 names one blob (x), its type and size, and the
// owner whose media it is.
func checkFileNote(ev *nostr.Event) (bool, string) {
	x := ev.Tags.GetFirst([]string{"x", ""})
	if x == nil || !isBlobHash((*x)[1]) {
		return true, "invalid: a file note needs an x tag of 64 lower-case hex"
	}
	if m := ev.Tags.GetFirst([]string{"m", ""}); m == nil || (*m)[1] == "" {
		return true, "invalid: a file note needs an m tag"
	}
	size := ev.Tags.GetFirst([]string{"size", ""})
	if size == nil {
		return true, "invalid: a file note needs a size tag"
	}
	if n, err := strconv.ParseInt((*size)[1], 10, 64); err != nil || n < 0 {
		return true, "invalid: size is not a byte count"
	}
	return checkFilesOwner(ev)
}

// checkFilesDeletion: a kind 5 here deletes file notes, and says so.
func checkFilesDeletion(ev *nostr.Event) (bool, string) {
	if ev.Tags.FindWithValue("k", strconv.Itoa(kindFileMetadata)) == nil {
		return true, "invalid: a deletion here needs [\"k\",\"1063\"]"
	}
	if ev.Tags.GetFirst([]string{"e", ""}) == nil {
		return true, "invalid: a deletion here names the notes it deletes (e tags)"
	}
	return checkFilesOwner(ev)
}

// checkFilesOwner: v1 keeps the owner's media only (p = the vault owner).
func checkFilesOwner(ev *nostr.Event) (bool, string) {
	if config.OwnerPubKey == "" {
		return true, "restricted: this vault has no owner yet"
	}
	ps := tagValues(ev.Tags, "p")
	if len(ps) != 1 || ps[0] != config.OwnerPubKey {
		return true, "restricted: media notes here are for this vault's owner only (one p tag)"
	}
	return false, ""
}

// rejectFilesDuplicate: one note per (signing device, blob). A second is
// answered duplicate:, which a sender's queue counts as done.
func rejectFilesDuplicate(ctx context.Context, ev *nostr.Event) (bool, string) {
	if ev.Kind != kindFileMetadata {
		return false, ""
	}
	x := (*ev.Tags.GetFirst([]string{"x", ""}))[1]
	if filesHasNote(ctx, ev.PubKey, x) {
		return true, "duplicate: this device already has a note for this file"
	}
	return false, ""
}

func filesHasNote(ctx context.Context, author, x string) bool {
	if filesDB == nil {
		return false
	}
	ch, err := filesDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{kindFileMetadata}, Authors: []string{author}, Tags: nostr.TagMap{"x": []string{x}}, Limit: 1})
	if err != nil {
		return false
	}
	found := false
	for range ch {
		found = true
	}
	return found
}

// rejectFilesDeleted: a deleted note can't come back. Any kind 5 stored here
// counts (only trusted keys can store one), not just the author's: one
// device deletes another's note.
func rejectFilesDeleted(ctx context.Context, ev *nostr.Event) (bool, string) {
	if filesDB == nil || ev.Kind != kindFileMetadata {
		return false, ""
	}
	ch, err := filesDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{nostr.KindDeletion}, Tags: nostr.TagMap{"e": []string{ev.ID}}, Limit: 1})
	if err != nil {
		return false, ""
	}
	deleted := false
	for range ch {
		deleted = true
	}
	if deleted {
		return true, "blocked: this note has been deleted"
	}
	return false, ""
}

// filesDeletionOutcome: any trusted key may delete any file note here; a
// kind 5 can't delete anything that is not a file note.
func filesDeletionOutcome(_ context.Context, target, deletion *nostr.Event) (bool, string) {
	if target.Kind != kindFileMetadata {
		return false, "only file notes can be deleted here"
	}
	if !filesWriter(deletion.PubKey) {
		return false, "only this vault's paired devices delete media notes"
	}
	// khatru deletes before RejectEvent runs: a malformed deletion must not
	// delete first and be refused after.
	if bad, msg := checkFilesDeletion(deletion); bad {
		return false, msg
	}
	return true, ""
}

// rejectFilesRead: AUTHed (policies.MustAuth runs first) as a key that may read.
func rejectFilesRead(ctx context.Context, _ nostr.Filter) (bool, string) {
	if !filesReader(khatru.GetAuthed(ctx)) {
		return true, "restricted: media notes are read by this vault's owner and paired devices only"
	}
	return false, ""
}

// queryTrustedFiles answers from filesDB, without the notes and deletions of
// a key that is no longer trusted (an unpaired device).
func queryTrustedFiles(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	out := make(chan *nostr.Event)
	if filesDB == nil {
		close(out)
		return out, nil
	}
	ch, err := filesDB.QueryEvents(ctx, f)
	if err != nil {
		close(out)
		return out, err
	}
	go func() {
		defer close(out)
		for ev := range ch { // drained to the end, so the store's query finishes
			if !filesWriter(ev.PubKey) {
				continue
			}
			select {
			case out <- ev:
			case <-ctx.Done():
			}
		}
	}()
	return out, nil
}

// filesPreventBroadcast: a live note is sent only to a connection AUTHed as
// a reader, and only if its signer is still trusted.
func filesPreventBroadcast(ws *khatru.WebSocket, ev *nostr.Event) bool {
	return !filesReader(ws.AuthedPublicKey) || !filesWriter(ev.PubKey)
}

// filesBlobGone: the vault deleted a blob, so it posts one kind 5 (its own
// key) for every note naming that hash, and every open Media tab drops the
// tile. Logen's pick (b), 2026-11-12.
func filesBlobGone(ctx context.Context, sha string) {
	if filesDB == nil || filesRelay == nil || config.OwnerPubKey == "" || !isBlobHash(sha) {
		return
	}
	sk := filesVaultSecret()
	if sk == "" {
		return
	}
	ch, err := filesDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{kindFileMetadata}, Tags: nostr.TagMap{"x": []string{sha}}})
	if err != nil {
		return
	}
	var notes []*nostr.Event
	for ev := range ch {
		notes = append(notes, ev)
	}
	if len(notes) == 0 {
		return
	}
	del := nostr.Event{Kind: nostr.KindDeletion, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"k", strconv.Itoa(kindFileMetadata)}, {"x", sha}, {"p", config.OwnerPubKey},
	}}
	for _, n := range notes {
		del.Tags = append(del.Tags, nostr.Tag{"e", n.ID})
	}
	if err := del.Sign(sk); err != nil {
		return
	}
	for _, n := range notes {
		if err := filesDB.DeleteEvent(ctx, n); err != nil {
			slog.Warn("files: deleting a note for a removed blob", "error", err)
		}
	}
	if err := filesDB.SaveEvent(ctx, &del); err != nil {
		slog.Warn("files: saving the deletion for a removed blob", "error", err)
		return
	}
	filesRelay.BroadcastEvent(&del)
}

// filesNow is the clock the backfill stamps notes with (tests set it).
var filesNow = time.Now
