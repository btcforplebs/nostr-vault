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
// A delete reaches exactly as far as the original did (Tron #1997 D1): a
// Blossom DELETE removes only one account's record of the blob, the
// signer's, or the owner's for a paired device (meshIndexKey). Each kept
// delete names that account, and every other device drops only that
// account's records. A delete beats a record no newer than it: a photo
// uploaded again after its delete comes back (its new record is newer).
//
// Which deletes a device takes from a peer, and for which account: one
// signed by an own account (that account), by a device paired here or this
// vault's own mesh key (the owner), or, from a peer, one the peer filed for
// the owner (a device paired only to the peer). The peer is trusted by its
// live copy token and files only deletes it took itself or vetted the same
// way. A tag the signer picks never widens it.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
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
	// Owner: the account whose record the original delete removed.
	Owner string `json:"owner"`
	At    int64  `json:"at"`
}

// copyDeleteKey: a kept delete is filed per hash and account.
func copyDeleteKey(sha, owner string) string { return sha + ":" + owner }

var (
	copyDeletesMu sync.Mutex
	// The parsed file, kept while the file on disk is unchanged: the list
	// is read for every file a catch-up offers or takes (Tron #1997 S).
	copyDeletesCache    map[string]copyDelete
	copyDeletesCacheKey string
)

// copyDeletesStamp: which file, and which write of it, the cache holds.
func copyDeletesStamp() string {
	abs, _ := filepath.Abs(copyDeletesFile)
	st, err := os.Stat(abs)
	if err != nil {
		return abs + "|none"
	}
	return abs + "|" + strconv.FormatInt(st.ModTime().UnixNano(), 10) + "|" + strconv.FormatInt(st.Size(), 10)
}

// loadCopyDeletes: the kept deletes (copyDeletesMu held). The map is the
// cache: callers that change it save it.
func loadCopyDeletes() map[string]copyDelete {
	stamp := copyDeletesStamp()
	if copyDeletesCache != nil && stamp == copyDeletesCacheKey {
		return copyDeletesCache
	}
	out := map[string]copyDelete{}
	if raw, err := os.ReadFile(copyDeletesFile); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	for k, d := range out {
		if d.Ev == nil || d.Owner == "" {
			delete(out, k)
		}
	}
	copyDeletesCache, copyDeletesCacheKey = out, stamp
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
	copyDeletesCache, copyDeletesCacheKey = all, copyDeletesStamp()
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

// copyDeleteOwner: the account whose records ev deletes here, or "" when
// it may not delete here (see the top). peer: the sending device's hex mesh
// key ("" for this device's own); claimed: the account the peer filed it for.
func copyDeleteOwner(ev *nostr.Event, peer, claimed string) string {
	accounts := copyAccounts()
	if accounts[ev.PubKey] {
		return ev.PubKey
	}
	owner := config.OwnerPubKey
	if owner == "" || !accounts[owner] {
		return ""
	}
	self := meshDevices.selfKey()
	if (self != "" && ev.PubKey == self) || meshDevices.paired(ev.PubKey) {
		return owner
	}
	// A device paired only to the peer: the peer vouches, and only for the
	// owner (a device's delete only ever removes the owner's record).
	if peer != "" && claimed == owner {
		return owner
	}
	return ""
}

// keepCopyDelete files ev for owner under each hash it deletes, unless a
// newer delete is there already. Returns the hashes it filed (to apply).
func keepCopyDelete(ev *nostr.Event, owner string, now time.Time) []string {
	shas := copyDeleteHashes(ev, now)
	if len(shas) == 0 || owner == "" {
		return nil
	}
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	all := loadCopyDeletes()
	var filed []string
	for _, sha := range shas {
		key := copyDeleteKey(sha, owner)
		if old, ok := all[key]; ok && old.Ev.CreatedAt >= ev.CreatedAt {
			continue
		}
		all[key] = copyDelete{Ev: ev, Owner: owner, At: now.Unix()}
		filed = append(filed, sha)
	}
	if len(filed) > 0 {
		saveCopyDeletes(all)
	}
	return filed
}

// copyDeletedAt: copyDeleteKey(sha256, account) -> the created_at of its
// delete. Read once per catch-up round or request, not per file.
func copyDeletedAt() map[string]int64 {
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	all := loadCopyDeletes()
	out := make(map[string]int64, len(all))
	for k, d := range all {
		out[k] = int64(d.Ev.CreatedAt)
	}
	return out
}

// copyIsDeleted: pubkey's record of sha, from recordAt, is on the delete list.
func copyIsDeleted(deleted map[string]int64, sha, pubkey string, recordAt int64) bool {
	at, ok := deleted[copyDeleteKey(sha, pubkey)]
	return ok && recordAt <= at
}

// copyDeleteItem: one delete on the wire, with the account it was filed for.
type copyDeleteItem struct {
	Ev    *nostr.Event `json:"ev"`
	Owner string       `json:"owner"`
}

// copyDeletesSince: the deletes this device learned at or after since.
func copyDeletesSince(since int64) []copyDeleteItem {
	copyDeletesMu.Lock()
	defer copyDeletesMu.Unlock()
	seen := map[string]bool{}
	var out []copyDeleteItem
	for _, d := range loadCopyDeletes() {
		if d.At < since || seen[d.Ev.ID+d.Owner] {
			continue
		}
		seen[d.Ev.ID+d.Owner] = true
		out = append(out, copyDeleteItem{Ev: d.Ev, Owner: d.Owner})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ev.CreatedAt > out[j].Ev.CreatedAt })
	return out
}

// applyCopyDelete removes, for sha, owner's records no newer than at, and
// the file once no record is left (as a Blossom DELETE does). Records of
// any other account stay, and so does the file. Returns whether it went.
func applyCopyDelete(ctx context.Context, sha, owner string, at int64) bool {
	if blossomDB == nil {
		return false
	}
	ch, err := blossomDB.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{Kinds: []int{24242}, Tags: nostr.TagMap{"x": []string{sha}}})
	if err != nil {
		return false
	}
	var drop []*nostr.Event
	left := false
	for ev := range ch {
		if ev.PubKey == owner && int64(ev.CreatedAt) <= at {
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
func takeCopyDeletes(ctx context.Context, items []copyDeleteItem, peer string) int {
	gone := 0
	now := time.Now()
	for _, it := range items {
		if it.Ev == nil {
			continue
		}
		owner := copyDeleteOwner(it.Ev, peer, it.Owner)
		if owner == "" {
			continue
		}
		for _, sha := range keepCopyDelete(it.Ev, owner, now) {
			if applyCopyDelete(ctx, sha, owner, int64(it.Ev.CreatedAt)) {
				gone++
			}
		}
	}
	return gone
}

// ─── this device's own deletes ─────────────────────────────────────────────

// The Blossom DELETE hands the signed event to RejectDelete and only the
// hash to DeleteBlob: the last RejectDelete notes it, DeleteBlob files it
// once the file is really gone. Only an own account's or a paired device's
// delete is noted (the https port takes a DELETE from any key), an entry
// lives copyPendingDeleteTTL at most (a DELETE that removed no file never
// reaches DeleteBlob), and the map holds copyPendingDeleteMax at most
// (Tron #1997 D2).
const (
	copyPendingDeleteTTL = 2 * time.Minute
	copyPendingDeleteMax = 256
)

type copyPending struct {
	ev    *nostr.Event
	owner string
	at    time.Time
}

var (
	copyPendingDeleteMu sync.Mutex
	copyPendingDelete   = map[string]copyPending{}
	copyPendingNow      = time.Now
)

// noteCopyDeleteAuth is the last RejectDelete: it never refuses.
func noteCopyDeleteAuth(ctx context.Context, auth *nostr.Event, sha string, _ string) (bool, string, int) {
	if auth == nil || !isBlobHash(sha) {
		return false, "", 0
	}
	// The account whose record this DELETE removes (meshOwnerIndex).
	owner := ""
	switch {
	case isMeshDeviceAuth(ctx, auth):
		if o := meshIndexKey(ctx, auth.PubKey); o != auth.PubKey {
			owner = o
		}
	case copyAccounts()[auth.PubKey]:
		owner = auth.PubKey
	}
	if owner == "" {
		return false, "", 0
	}
	now := copyPendingNow()
	copyPendingDeleteMu.Lock()
	defer copyPendingDeleteMu.Unlock()
	for k, p := range copyPendingDelete {
		if now.Sub(p.at) > copyPendingDeleteTTL {
			delete(copyPendingDelete, k)
		}
	}
	if _, ok := copyPendingDelete[sha]; !ok && len(copyPendingDelete) >= copyPendingDeleteMax {
		oldest := ""
		for k, p := range copyPendingDelete {
			if oldest == "" || p.at.Before(copyPendingDelete[oldest].at) {
				oldest = k
			}
		}
		delete(copyPendingDelete, oldest)
	}
	copyPendingDelete[sha] = copyPending{ev: auth, owner: owner, at: now}
	return false, "", 0
}

// keepOwnCopyDelete files the delete that removed sha here (DeleteBlob).
func keepOwnCopyDelete(sha string) {
	copyPendingDeleteMu.Lock()
	p, ok := copyPendingDelete[sha]
	delete(copyPendingDelete, sha)
	copyPendingDeleteMu.Unlock()
	if !ok || copyPendingNow().Sub(p.at) > copyPendingDeleteTTL {
		return
	}
	if len(keepCopyDelete(p.ev, p.owner, time.Now())) == 0 {
		slog.Debug("copy delete list: delete not kept", "sha256", sha)
	}
}

// ─── the catch-up ──────────────────────────────────────────────────────────

type copyDeleteList struct {
	Deletes []copyDeleteItem `json:"deletes"`
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
