//go:build !(js && wasm)

package main

// The delete list (multi-Mac rules §3.5, Tron #1997 M1).
//
// A Blossom DELETE on one device removes only its own file. With the
// owner's devices pulling each other's files, the photo would stay on every
// other full-copy device, and one that later catches up with it would pull
// it back (and the web Mac would serve it again). So each device keeps the
// signed delete it took, one per hash: the kind 24242 `t=delete` event the
// owner's app (account key) or a paired device (its mesh key) sent. The
// engine signs nothing; it keeps what it was handed. A catch-up swaps the
// lists first, before any file is offered, each side applies the other's,
// and a hash on the list is left out of the file list and the file GET.
//
// A delete beats a file whose record is no newer than it: a photo uploaded
// again after its delete comes back (its new record is newer).
//
// Which deletes a device takes from a peer: one signed by an own account,
// by a device paired here (or this vault's own mesh key), or by a device
// key whose token named this vault or the sending peer (the peer took it
// from one of its own paired devices). Every delete arrives only behind a
// live copy token, so only an own paired device can hand one over.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

const (
	copyDeletesFile = "copy_deletes.json"
	// copyDeletesMax: deletes kept, newest first (about 500 bytes each).
	copyDeletesMax = 20000
	// copyDeletesMaxBody: the most one side sends the other in one round.
	copyDeletesMaxBody = 16 << 20
)

// copyDelete is one kept delete: the signed event, and when this device
// learned it (what a peer's next catch-up asks from).
type copyDelete struct {
	Ev *nostr.Event `json:"ev"`
	At int64        `json:"at"`
}

var copyDeletesMu sync.Mutex

func loadCopyDeletes() map[string]copyDelete {
	out := map[string]copyDelete{}
	if raw, err := os.ReadFile(copyDeletesFile); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

func saveCopyDeletes(all map[string]copyDelete) {
	if len(all) > copyDeletesMax {
		shas := make([]string, 0, len(all))
		for sha := range all {
			shas = append(shas, sha)
		}
		sort.Slice(shas, func(i, j int) bool { return all[shas[i]].Ev.CreatedAt > all[shas[j]].Ev.CreatedAt })
		for _, sha := range shas[copyDeletesMax:] {
			delete(all, sha)
		}
	}
	raw, _ := json.Marshal(all)
	tmp := copyDeletesFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copyDeletesFile)
	}
}

// copyDeleteHashes: the blobs ev deletes, when it is a signed kind 24242
// `t=delete` not dated in the future; nil otherwise.
func copyDeleteHashes(ev *nostr.Event, now time.Time) []string {
	if ev == nil || ev.Kind != 24242 || !ev.CheckID() || ev.CreatedAt.Time().After(now.Add(maxFutureSkew)) {
		return nil
	}
	if ts := tagValues(ev.Tags, "t"); len(ts) != 1 || ts[0] != "delete" {
		return nil
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return nil
	}
	var out []string
	for _, x := range tagValues(ev.Tags, "x") {
		if x = strings.ToLower(x); isBlobHash(x) {
			out = append(out, x)
		}
	}
	return out
}

// copyDeleteSignerOK: ev's signer may delete here (see the top).
// peer: the sending device's hex mesh key ("" for this device's own).
func copyDeleteSignerOK(ev *nostr.Event, peer string) bool {
	if copyAccounts()[ev.PubKey] {
		return true
	}
	self := meshDevices.selfKey()
	if (self != "" && ev.PubKey == self) || meshDevices.paired(ev.PubKey) {
		return true
	}
	for _, p := range tagValues(ev.Tags, "p") {
		if k := meshKeyHex(p); k != "" && ((self != "" && k == self) || (peer != "" && k == peer)) {
			return true
		}
	}
	return false
}

// keepCopyDelete files ev under each hash it deletes, unless a newer delete
// is there already. Returns the hashes it filed (to apply).
func keepCopyDelete(ev *nostr.Event, now time.Time) []string {
	shas := copyDeleteHashes(ev, now)
	if len(shas) == 0 {
		return nil
	}
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	all := loadCopyDeletes()
	var filed []string
	for _, sha := range shas {
		if old, ok := all[sha]; ok && old.Ev.CreatedAt >= ev.CreatedAt {
			continue
		}
		all[sha] = copyDelete{Ev: ev, At: now.Unix()}
		filed = append(filed, sha)
	}
	if len(filed) > 0 {
		saveCopyDeletes(all)
	}
	return filed
}

// copyDeletedAt: sha256 -> the created_at of its delete.
func copyDeletedAt() map[string]int64 {
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	out := map[string]int64{}
	for sha, d := range loadCopyDeletes() {
		if d.Ev != nil {
			out[sha] = int64(d.Ev.CreatedAt)
		}
	}
	return out
}

// copyIsDeleted: a file whose record is from recordAt is on the delete list.
func copyIsDeleted(deleted map[string]int64, sha string, recordAt int64) bool {
	at, ok := deleted[sha]
	return ok && recordAt <= at
}

// copyDeletesSince: the deletes this device learned at or after since.
func copyDeletesSince(since int64) []*nostr.Event {
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	seen := map[string]bool{}
	var out []*nostr.Event
	for _, d := range loadCopyDeletes() {
		if d.Ev == nil || d.At < since || seen[d.Ev.ID] {
			continue
		}
		seen[d.Ev.ID] = true
		out = append(out, d.Ev)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out
}

// applyCopyDelete removes, for sha, every own record no newer than at, and
// the file once no record is left (as a Blossom DELETE does). Returns
// whether the file went.
func applyCopyDelete(ctx context.Context, sha string, at int64) bool {
	if blossomDB == nil {
		return false
	}
	ch, err := blossomDB.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{Kinds: []int{24242}, Tags: nostr.TagMap{"x": []string{sha}}})
	if err != nil {
		return false
	}
	var drop []*nostr.Event
	left := false
	accounts := copyAccounts()
	for ev := range ch {
		if accounts[ev.PubKey] && int64(ev.CreatedAt) <= at {
			drop = append(drop, ev)
		} else {
			left = true
		}
	}
	for _, ev := range drop {
		if err := blossomDB.DeleteEvent(ctx, ev); err != nil {
			left = true
		}
	}
	if left || copyBlobFile(sha) == "" {
		return false
	}
	if err := deleteBlobFiles(sha); err != nil {
		slog.Warn("copy catch-up: delete list file not removed", "sha256", sha, "error", err)
		return false
	}
	filesBlobGone(ctx, sha)
	return true
}

// takeCopyDeletes keeps and applies a peer's deletes. Returns how many
// files went.
func takeCopyDeletes(ctx context.Context, evs []*nostr.Event, peer string) int {
	gone := 0
	now := time.Now()
	for _, ev := range evs {
		if ev == nil || !copyDeleteSignerOK(ev, peer) {
			continue
		}
		for _, sha := range keepCopyDelete(ev, now) {
			if applyCopyDelete(ctx, sha, int64(ev.CreatedAt)) {
				gone++
			}
		}
	}
	return gone
}

// ─── this device's own deletes ─────────────────────────────────────────────

// The Blossom DELETE hands the signed event to RejectDelete and only the
// hash to DeleteBlob: the last RejectDelete notes it, DeleteBlob files it
// once the file is really gone.
var (
	copyPendingDeleteMu sync.Mutex
	copyPendingDelete   = map[string]*nostr.Event{}
)

// noteCopyDeleteAuth is the last RejectDelete: it never refuses.
func noteCopyDeleteAuth(_ context.Context, auth *nostr.Event, sha string, _ string) (bool, string, int) {
	if auth != nil && isBlobHash(sha) {
		copyPendingDeleteMu.Lock()
		copyPendingDelete[sha] = auth
		copyPendingDeleteMu.Unlock()
	}
	return false, "", 0
}

// keepOwnCopyDelete files the delete that removed sha here (DeleteBlob).
func keepOwnCopyDelete(sha string) {
	copyPendingDeleteMu.Lock()
	auth := copyPendingDelete[sha]
	delete(copyPendingDelete, sha)
	copyPendingDeleteMu.Unlock()
	if auth == nil {
		return
	}
	if len(keepCopyDelete(auth, time.Now())) == 0 {
		slog.Debug("copy delete list: delete not kept", "sha256", sha)
	}
}

// ─── the catch-up ──────────────────────────────────────────────────────────

type copyDeleteList struct {
	Deletes []*nostr.Event `json:"deletes"`
}

// serveSyncDeletes: GET hands over what this device learned since `since`;
// PUT keeps and applies the caller's.
func (s *copyServer) serveSyncDeletes(w http.ResponseWriter, r *http.Request, tokenHash string) {
	switch r.Method {
	case http.MethodGet:
		since := int64(0)
		if v := r.URL.Query().Get("since"); v != "" {
			since, _ = strconv.ParseInt(v, 10, 64)
		}
		copyJSON(w, http.StatusOK, copyDeleteList{Deletes: copyDeletesSince(since)})
	case http.MethodPut:
		var in copyDeleteList
		if err := json.NewDecoder(io.LimitReader(r.Body, copyDeletesMaxBody)).Decode(&in); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		gone := takeCopyDeletes(r.Context(), in.Deletes, s.tokenDevice(tokenHash))
		copyJSON(w, http.StatusOK, map[string]int{"gone": gone})
	default:
		http.NotFound(w, r)
	}
}

// syncDeletes swaps the delete lists with A: A's first (kept, applied),
// then B's. An A from before this answers 404: nothing to take, and B's
// own still keeps its files out of what it lists. Any other failure stops
// the round, so no file moves before the lists are swapped.
func (c *copyClient) syncDeletes(ctx context.Context, since int64) (int, error) {
	// B's own, read before A's are kept: A's are not sent back to it.
	mine := copyDeletesSince(since)
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/deletes?since="+strconv.FormatInt(since, 10), nil, nil)
	if err != nil {
		return 0, err
	}
	var theirs copyDeleteList
	switch resp.StatusCode {
	case http.StatusOK:
		err = json.NewDecoder(io.LimitReader(resp.Body, copyDeletesMaxBody)).Decode(&theirs)
		resp.Body.Close()
		if err != nil {
			return 0, err
		}
	case http.StatusNotFound:
		resp.Body.Close()
		return 0, nil
	default:
		resp.Body.Close()
		return 0, statusError(resp.StatusCode)
	}
	gone := takeCopyDeletes(ctx, theirs.Deletes, meshKeyHex(strings.TrimSpace(c.peer)))
	if len(mine) == 0 {
		return gone, nil
	}
	raw, _ := json.Marshal(copyDeleteList{Deletes: mine})
	resp, err = c.do(ctx, http.MethodPut, "/copy/v2/sync/deletes", map[string]string{"Content-Type": "application/json"}, raw)
	if err != nil {
		return gone, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return gone, statusError(resp.StatusCode)
	}
	return gone, nil
}
