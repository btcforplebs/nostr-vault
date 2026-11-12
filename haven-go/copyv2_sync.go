//go:build !(js && wasm)

package main

// Mesh vault copy v2: the catch-up on every reconnect (docs/MESH_COPY_V2_CONTRACT.md §6).
// An id-list diff over the copy token, not NIP-77: the engine holds no owner
// key to answer NIP-42 for /private and /chat. Every event either side takes
// from the other goes through importOne, the restore's own checks (id,
// signature, the store's author rule, NIP-09 deletions): audit #14.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// copySyncStores: the stores the catch-up keeps the same on both devices.
var copySyncStores = []string{"outbox", "private", "chat", "inbox"}

const (
	copySyncPageDefault = 5000
	copySyncBatch       = 500
	copySyncMaxBody     = 32 << 20
	copySyncOverlap     = 7 * 24 * time.Hour // gift wraps backdate up to 2 days
	copySyncFile        = "copy_sync.json"
	// copySyncNotesOnlyMark keys a light device's rounds apart from full ones.
	copySyncNotesOnlyMark = "#notes"
	copySyncMaxFiles      = 2000
)

// copySyncPage: ids per page of A's list (a var so a test can page small).
var copySyncPage = copySyncPageDefault

// copyNotCaughtUp: the stores in unreadable that no catch-up covers. A copy
// that left one of them out is done, but nothing later brings its events
// over, so the done line names them (Tron #1864).
func copyNotCaughtUp(unreadable []string) []string {
	var out []string
	for _, store := range unreadable {
		if !slices.Contains(copySyncStores, store) {
			out = append(out, store)
		}
	}
	return out
}

func copySyncDB(store string) DBBackend {
	if !slices.Contains(copySyncStores, store) {
		return nil
	}
	return dbs[store]
}

// ─── A: the endpoints ──────────────────────────────────────────────────────

func (s *copyServer) store(name string) DBBackend {
	if s.syncDB != nil {
		return s.syncDB(name)
	}
	return copySyncDB(name)
}

func (s *copyServer) serveSync(w http.ResponseWriter, r *http.Request, what string) {
	tokenHash, ok := s.bearer(r)
	if !ok {
		http.Error(w, "auth_refused", http.StatusUnauthorized)
		return
	}
	ctx := r.Context()
	q := r.URL.Query()
	switch {
	case what == "ids" && r.Method == http.MethodGet:
		db := s.store(q.Get("store"))
		if db == nil {
			http.Error(w, "unknown store", http.StatusBadRequest)
			return
		}
		since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
		until, _ := strconv.ParseInt(q.Get("until"), 10, 64)
		after := q.Get("after")
		if after != "" && !copyIsHex(after, 64) {
			http.Error(w, "bad cursor", http.StatusBadRequest)
			return
		}
		ids, more, err := copyListIDs(ctx, db, since, until, after)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		copyJSON(w, http.StatusOK, map[string]any{"ids": ids, "more": more})
	case what == "events" && r.Method == http.MethodPost:
		var req struct {
			Store string   `json:"store"`
			IDs   []string `json:"ids"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil || len(req.IDs) > copySyncBatch {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		db := s.store(req.Store)
		if db == nil {
			http.Error(w, "unknown store", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		_ = copyWriteEvents(ctx, db, req.IDs, w)
	case what == "put" && r.Method == http.MethodPost:
		db := s.store(q.Get("store"))
		if db == nil {
			http.Error(w, "unknown store", http.StatusBadRequest)
			return
		}
		st, err := importDBStats(ctx, db, io.LimitReader(r.Body, copySyncMaxBody))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		copyJSON(w, http.StatusOK, map[string]int{"stored": st.stored, "dup": st.dup, "skipped": st.skipped, "bad": st.bad})
	case what == "files" && r.Method == http.MethodGet:
		since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
		until, _ := strconv.ParseInt(q.Get("until"), 10, 64)
		files, more, err := copyOwnFilesSince(ctx, since, until, q.Get("after"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		copyJSON(w, http.StatusOK, map[string]any{"files": files, "more": more})
	case strings.HasPrefix(what, "file/") && r.Method == http.MethodGet:
		sha := strings.TrimPrefix(what, "file/")
		own, err := copyOwnMediaSet(ctx)
		if err != nil {
			// Not a 404: B keeps the file in its window and asks again.
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if !own[sha] {
			// Only the owner's own files leave over this path (pick 6, §4).
			http.NotFound(w, r)
			return
		}
		path := copyBlobFile(sha)
		if path == "" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, path)
	case what == "accounts" && r.Method == http.MethodGet:
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(marshalLocalCopyAccounts())
	case what == "accounts" && r.Method == http.MethodPut:
		// B's accounts, merged into A's when they share one (§3.4). Never removes.
		raw, err := io.ReadAll(io.LimitReader(r.Body, copyAccountsMaxSize+1))
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		copyJSON(w, http.StatusOK, map[string]string{"accounts": takeCopyAccounts(raw)})
	case what == "device":
		s.serveSyncDevice(w, r, tokenHash)
	case what == "settings" && r.Method == http.MethodGet:
		raw, err := os.ReadFile(copySettingsFile)
		if err != nil || copySettingsRefusal(raw, time.Now()) != "" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	case what == "settings" && r.Method == http.MethodPut:
		raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		copyJSON(w, http.StatusOK, map[string]string{"settings": storeCopySettings(raw)})
	default:
		http.NotFound(w, r)
	}
}

// copyListIDs: one page of [id, created_at], newest first and, within one
// second, by id. With until and after set, only what comes after that
// cursor: of second until with an id above after, or older. With until
// alone (a B from before the cursor), second until and older. A page never
// ends partway into a second it did not read whole, so the cursor of its
// last entry loses nothing: the store's own limit cuts its oldest second
// anywhere, not by id, and paging on created_at alone skipped or never got
// past a second with more events than a page.
func copyListIDs(ctx context.Context, db DBBackend, since, until int64, after string) ([][2]any, bool, error) {
	var evs []*nostr.Event
	more := false
	older := until // the older read's until, inclusive (0: none)
	if until > 0 && after != "" {
		same, err := copySecond(ctx, db, until)
		if err != nil {
			return nil, false, err
		}
		for _, ev := range same {
			if ev.ID > after {
				evs = append(evs, ev)
			}
		}
		older = until - 1
	}
	if room := copySyncPage + 1 - len(evs); room <= 0 {
		more = true
	} else if (until == 0 || older > 0) && (since == 0 || older == 0 || older >= since) {
		f := nostr.Filter{Limit: room}
		if since > 0 {
			ts := nostr.Timestamp(since)
			f.Since = &ts
		}
		if older > 0 {
			ts := nostr.Timestamp(older)
			f.Until = &ts
		}
		got, err := copyQuery(ctx, db, f)
		if err != nil {
			return nil, false, err
		}
		if len(got) == room {
			// The store may have cut its oldest second: drop it, or, when
			// the whole read is that one second, read it whole.
			more = true
			copySortIDs(got)
			edge := got[len(got)-1].CreatedAt
			if got[0].CreatedAt == edge {
				if got, err = copySecond(ctx, db, int64(edge)); err != nil {
					return nil, false, err
				}
			} else {
				got = slices.DeleteFunc(got, func(ev *nostr.Event) bool { return ev.CreatedAt == edge })
			}
		}
		evs = append(evs, got...)
	}
	copySortIDs(evs)
	if len(evs) > copySyncPage {
		evs = evs[:copySyncPage]
		more = true
	}
	out := make([][2]any, len(evs))
	for i, ev := range evs {
		out[i] = [2]any{ev.ID, int64(ev.CreatedAt)}
	}
	return out, more, nil
}

// copySecondMax: the most events copySecond reads in one second. A second
// that holds more is refused, not listed short.
const copySecondMax = 40_000

// copySecond: every event stamped at, whole.
func copySecond(ctx context.Context, db DBBackend, at int64) ([]*nostr.Event, error) {
	ts := nostr.Timestamp(at)
	evs, err := copyQuery(ctx, db, nostr.Filter{Since: &ts, Until: &ts, Limit: copySecondMax})
	if err != nil {
		return nil, err
	}
	if len(evs) >= copySecondMax {
		return nil, fmt.Errorf("copy catch-up: more than %d events in second %d", copySecondMax-1, at)
	}
	return evs, nil
}

func copyQuery(ctx context.Context, db DBBackend, f nostr.Filter) ([]*nostr.Event, error) {
	ch, err := db.QueryEvents(eventstore.SetNegentropy(ctx), f)
	if err != nil {
		return nil, err
	}
	var evs []*nostr.Event
	for ev := range ch {
		evs = append(evs, ev)
	}
	// Close cuts an open query short without an error.
	if g, ok := db.(*gatedDB); ok && g.isClosing() {
		return nil, errDBClosing
	}
	return evs, nil
}

func copySortIDs(evs []*nostr.Event) {
	sort.Slice(evs, func(i, j int) bool {
		if evs[i].CreatedAt != evs[j].CreatedAt {
			return evs[i].CreatedAt > evs[j].CreatedAt
		}
		return evs[i].ID < evs[j].ID
	})
}

// copyWriteEvents writes the events of ids as JSONL. Kind 5 first: a
// receiver that stores a note before its deletion arrives would keep a
// deleted note (audit #15).
func copyWriteEvents(ctx context.Context, db DBBackend, ids []string, w io.Writer) error {
	if len(ids) == 0 {
		return nil
	}
	ch, err := db.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{IDs: ids})
	if err != nil {
		return err
	}
	var evs []*nostr.Event
	for ev := range ch {
		evs = append(evs, ev)
	}
	sort.SliceStable(evs, func(i, j int) bool { return evs[i].Kind == nostr.KindDeletion && evs[j].Kind != nostr.KindDeletion })
	for _, ev := range evs {
		// Deleted here but still stored (its kind 5 came in later): never sent.
		if ev.Kind != nostr.KindDeletion && (isDeleted(ctx, db, ev) || (outboxDB != nil && db != outboxDB && isDeleted(ctx, outboxDB, ev))) {
			continue
		}
		if _, err := fmt.Fprintln(w, ev); err != nil {
			return err
		}
	}
	return nil
}

// copyFile is one own upload on the catch-up's list.
type copyFile struct {
	SHA256    string `json:"sha256"`
	Pubkey    string `json:"pubkey"`
	Type      string `json:"type"`
	Size      string `json:"size"`
	CreatedAt int64  `json:"created_at"`
}

// copyOwnMediaSet: the owner's own files (contract §4) on this device, by hash.
func copyOwnMediaSet(ctx context.Context) (map[string]bool, error) {
	accounts := copyAccounts()
	uploaders, _, err := copyOwnBlobRecords(ctx, accounts)
	if err != nil {
		return nil, err
	}
	return copyOwnMedia(uploaders, accounts), nil
}

// copyOwnFilesSince: own files whose record is at or after since, newest
// first (a second's files by sha256), at most copySyncMaxFiles. With until
// set, only files after the cursor (until, after) in that order: older than
// until, or of that second with a sha256 above after. more: older ones were
// cut; the caller asks again with the last file it got as the cursor.
func copyOwnFilesSince(ctx context.Context, since, until int64, after string) ([]copyFile, bool, error) {
	accounts := copyAccounts()
	uploaders, records, err := copyOwnBlobRecords(ctx, accounts)
	if err != nil {
		return nil, false, err
	}
	own := copyOwnMedia(uploaders, accounts)
	var out []copyFile
	for sha, rec := range records {
		at := int64(rec.CreatedAt)
		if at < since || (until > 0 && (at > until || (at == until && sha <= after))) || !own[sha] || copyBlobFile(sha) == "" {
			continue
		}
		f := copyFile{SHA256: sha, Pubkey: rec.PubKey, CreatedAt: int64(rec.CreatedAt)}
		if t := rec.Tags.GetFirst([]string{"type", ""}); t != nil {
			f.Type = (*t)[1]
		}
		if t := rec.Tags.GetFirst([]string{"size", ""}); t != nil {
			f.Size = (*t)[1]
		}
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].SHA256 < out[j].SHA256
	})
	more := len(out) > copySyncMaxFiles
	if more {
		out = out[:copySyncMaxFiles]
	}
	return out, more, nil
}

// ─── B: the client ─────────────────────────────────────────────────────────

var copySyncMu sync.Mutex

func loadCopySync() map[string]int64 {
	out := map[string]int64{}
	if raw, err := os.ReadFile(copySyncFile); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

// markCopySynced records a good catch-up (or the first copy) with peer at t.
func markCopySynced(peer string, t int64) {
	copySyncMu.Lock()
	defer copySyncMu.Unlock()
	all := loadCopySync()
	all[copyPeerKey(peer)] = t
	raw, _ := json.Marshal(all)
	tmp := copySyncFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copySyncFile)
	}
}

// clearCopySynced drops peer's catch-up marker: its next catch-up compares
// everything (since 0).
func clearCopySynced(peer string) {
	copySyncMu.Lock()
	defer copySyncMu.Unlock()
	all := loadCopySync()
	full, notes := copyPeerKey(peer), copyPeerKey(peer+copySyncNotesOnlyMark)
	_, hasFull := all[full]
	_, hasNotes := all[notes]
	if !hasFull && !hasNotes {
		return
	}
	delete(all, full)
	delete(all, notes)
	raw, _ := json.Marshal(all)
	tmp := copySyncFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copySyncFile)
	}
}

// copySyncResult: what one catch-up moved.
type copySyncResult struct {
	Got, Sent, Files int
	Settings         string
	Accounts         string
}

func (c *copyClient) store(name string) DBBackend {
	if c.syncDB != nil {
		return c.syncDB(name)
	}
	return copySyncDB(name)
}

// sync is one catch-up with A: notes both ways, own files A has, settings.
func (c *copyClient) sync(ctx context.Context) (copySyncResult, error) {
	var res copySyncResult
	c.token = copyPeerToken(c.peer)
	if c.token == "" {
		return res, copyErr("auth_refused")
	}
	// A light device's rounds keep their own mark: turning full copy on
	// later then starts the file pass from the beginning, not from the last
	// notes-only round (multi-Mac rules §3, rule 7).
	mark := c.peer
	if c.notesOnly {
		mark = c.peer + copySyncNotesOnlyMark
	}
	copySyncMu.Lock()
	last := loadCopySync()[copyPeerKey(mark)]
	copySyncMu.Unlock()
	started := time.Now().Unix()
	since := int64(0)
	if last > 0 {
		since = last - int64(copySyncOverlap/time.Second)
	}
	// Accounts first, both ways, so each side keeps the other's new accounts'
	// notes in this same round (§3.4, §6). They only ever merge.
	res.Accounts, _ = c.syncAccounts(ctx)
	// Each side's web domain, when it has one (copyv2_device.go).
	c.syncDevice(ctx)
	allIDs := true
	for _, store := range copySyncStores {
		db := c.store(store)
		if db == nil {
			continue
		}
		got, sent, complete, err := c.syncStore(ctx, store, db, since)
		res.Got += got
		res.Sent += sent
		if err != nil {
			return res, err
		}
		if !complete {
			allIDs = false
		}
	}
	files, allFiles := 0, true
	if !c.notesOnly {
		var err error
		files, allFiles, err = c.syncFiles(ctx, since)
		res.Files = files
		if err != nil {
			return res, err
		}
	}
	res.Settings, _ = c.syncSettings(ctx)
	// Marked only when every listed page was read: otherwise the next round
	// would start a week before now and never list the older notes and
	// files again.
	if allFiles && allIDs {
		markCopySynced(mark, started)
	}
	slog.Info("copy catch-up done", "got", res.Got, "sent", res.Sent, "files", res.Files, "settings", res.Settings, "accounts", res.Accounts)
	return res, nil
}

// remoteIDs lists A's ids in store since since, paged on (created_at, id).
// complete is false when A's list stopped paging (an A from before the
// cursor, stuck on a second fuller than a page): the round then syncs what
// it got but is not marked, so the rest stays in reach.
func (c *copyClient) remoteIDs(ctx context.Context, store string, since int64) (out map[string]bool, complete bool, err error) {
	out = map[string]bool{}
	until, after := int64(0), ""
	for {
		path := fmt.Sprintf("/copy/v2/sync/ids?store=%s&since=%d", store, since)
		if until > 0 {
			path += fmt.Sprintf("&until=%d&after=%s", until, after)
		}
		resp, err := c.do(ctx, http.MethodGet, path, nil, nil)
		if err != nil {
			return nil, false, err
		}
		var page struct {
			IDs  [][2]json.RawMessage `json:"ids"`
			More bool                 `json:"more"`
		}
		err = func() error {
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return statusError(resp.StatusCode)
			}
			return json.NewDecoder(io.LimitReader(resp.Body, 64<<20)).Decode(&page)
		}()
		if err != nil {
			return nil, false, err
		}
		lastAt, lastID := int64(0), ""
		for _, pair := range page.IDs {
			var id string
			var at int64
			if json.Unmarshal(pair[0], &id) != nil || json.Unmarshal(pair[1], &at) != nil || !copyIsHex(id, 64) || at <= 0 {
				continue
			}
			out[id] = true
			lastAt, lastID = at, id
		}
		if !page.More {
			return out, true, nil
		}
		// No step forward: the cursor would ask for the same page again.
		if lastAt == 0 || (lastAt == until && lastID <= after) || (until > 0 && lastAt > until) {
			slog.Warn("copy catch-up: id list did not page, the rest waits for the next round", "store", store)
			return out, false, nil
		}
		until, after = lastAt, lastID
	}
}

func copyLocalIDs(ctx context.Context, db DBBackend, since int64) (map[string]bool, error) {
	f := nostr.Filter{}
	if since > 0 {
		ts := nostr.Timestamp(since)
		f.Since = &ts
	}
	ch, err := db.QueryEvents(eventstore.SetNegentropy(ctx), f)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for ev := range ch {
		out[ev.ID] = true
	}
	return out, nil
}

func (c *copyClient) syncStore(ctx context.Context, store string, db DBBackend, since int64) (got, sent int, complete bool, err error) {
	theirs, complete, err := c.remoteIDs(ctx, store, since)
	if err != nil {
		return 0, 0, false, err
	}
	mine, err := copyLocalIDs(ctx, db, since)
	if err != nil {
		return 0, 0, false, err
	}
	var want, give []string
	for id := range theirs {
		if !mine[id] {
			want = append(want, id)
		}
	}
	for id := range mine {
		if !theirs[id] {
			give = append(give, id)
		}
	}
	slices.Sort(want)
	slices.Sort(give)
	for start := 0; start < len(want); start += copySyncBatch {
		batch := want[start:min(start+copySyncBatch, len(want))]
		body, _ := json.Marshal(map[string]any{"store": store, "ids": batch})
		resp, err := c.do(ctx, http.MethodPost, "/copy/v2/sync/events", map[string]string{"Content-Type": "application/json"}, body)
		if err != nil {
			return got, sent, false, err
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return got, sent, false, statusError(resp.StatusCode)
		}
		// Through the restore's checks: id, signature, author rule, deletions.
		st, err := importDBStats(ctx, db, io.LimitReader(resp.Body, copySyncMaxBody))
		resp.Body.Close()
		got += st.stored
		if err != nil {
			return got, sent, false, err
		}
	}
	for start := 0; start < len(give); start += copySyncBatch {
		batch := give[start:min(start+copySyncBatch, len(give))]
		var buf bytes.Buffer
		if err := copyWriteEvents(ctx, db, batch, &buf); err != nil {
			return got, sent, false, err
		}
		if buf.Len() == 0 {
			continue
		}
		resp, err := c.do(ctx, http.MethodPost, "/copy/v2/sync/put?store="+store, map[string]string{"Content-Type": "application/x-ndjson"}, buf.Bytes())
		if err != nil {
			return got, sent, false, err
		}
		var out struct{ Stored int }
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return got, sent, false, statusError(resp.StatusCode)
		}
		sent += out.Stored
	}
	return got, sent, complete, nil
}

func (c *copyClient) syncFiles(ctx context.Context, since int64) (int, bool, error) {
	n := 0
	seen := map[string]bool{}
	until, after := int64(0), ""
	for {
		path := fmt.Sprintf("/copy/v2/sync/files?since=%d", since)
		if until > 0 {
			path += fmt.Sprintf("&until=%d&after=%s", until, after)
		}
		resp, err := c.do(ctx, http.MethodGet, path, nil, nil)
		if err != nil {
			return n, false, err
		}
		var list struct {
			Files []copyFile
			More  bool
		}
		err = func() error {
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return statusError(resp.StatusCode)
			}
			return json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&list)
		}()
		if err != nil {
			return n, false, err
		}
		fresh := 0
		for _, f := range list.Files {
			if seen[f.SHA256] {
				continue
			}
			seen[f.SHA256] = true
			fresh++
			got, err := c.syncFile(ctx, f)
			if err != nil {
				return n, false, err
			}
			if got {
				n++
			}
		}
		if !list.More {
			return n, true, nil
		}
		// An A that ignores the cursor sends the same page again: stop, not
		// done, so the round is not marked and older files stay in reach.
		if fresh == 0 || len(list.Files) == 0 {
			slog.Warn("copy catch-up: file list did not page, older files wait for the next round")
			return n, false, nil
		}
		last := list.Files[len(list.Files)-1]
		until, after = last.CreatedAt, last.SHA256
	}
}

// syncFile fetches one own file A listed, unless it is here already. False
// when A answers 404 (not its own file, or gone) or the bytes don't match
// the hash: retrying would bring the same, so it does not hold the round
// back. Any other answer (a 5xx, a busy A) is an error, so the round stays
// unrecorded and the file stays in the window (Tron #1864).
func (c *copyClient) syncFile(ctx context.Context, f copyFile) (bool, error) {
	if !isBlobHash(f.SHA256) || copyBlobFile(f.SHA256) != "" {
		return false, nil
	}
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/file/"+f.SHA256, nil, nil)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return false, nil
	default:
		return false, statusError(resp.StatusCode)
	}
	ok, err := storeCopyBlob(f.SHA256, resp.Body)
	if err != nil || !ok {
		return false, err
	}
	// Its record, in Keep's shape, only now that the file is here.
	rec := &nostr.Event{PubKey: f.Pubkey, Kind: 24242, CreatedAt: nostr.Timestamp(f.CreatedAt),
		Tags: nostr.Tags{{"x", f.SHA256}, {"type", f.Type}, {"size", f.Size}}}
	rec.ID = rec.GetID()
	if blossomDB != nil {
		importBlobRecord(ctx, blossomDB, rec, time.Now())
	}
	return true, nil
}

// syncSettings: newest updated_at wins, a tie keeps each side's own.
func (c *copyClient) syncSettings(ctx context.Context) (string, error) {
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/settings", nil, nil)
	if err != nil {
		return "", err
	}
	theirs, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	var theirStamp int64
	if resp.StatusCode == http.StatusOK {
		var s copySettings
		if json.Unmarshal(theirs, &s) == nil {
			theirStamp = s.UpdatedAt
		}
	}
	mine := localCopySettingsStamp()
	switch {
	case copySettingsNewer(mine, theirStamp):
		return storeCopySettings(theirs), nil
	case copySettingsNewer(theirStamp, mine):
		raw, err := os.ReadFile(copySettingsFile)
		if err != nil || copySettingsRefusal(raw, time.Now()) != "" {
			return "refused", nil
		}
		resp, err := c.do(ctx, http.MethodPut, "/copy/v2/sync/settings", map[string]string{"Content-Type": "application/json"}, raw)
		if err != nil {
			return "", err
		}
		resp.Body.Close()
		return "sent", nil
	}
	return "same", nil
}

// syncAccounts: A's accounts merged into B's, then B's into A's. Each side
// takes the other's only when they share one (§3.4); nothing is removed.
// Returns what B did with A's ("added", "same" or the refusal).
func (c *copyClient) syncAccounts(ctx context.Context) (string, error) {
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/accounts", nil, nil)
	if err != nil {
		return "", err
	}
	theirs, _ := io.ReadAll(io.LimitReader(resp.Body, copyAccountsMaxSize+1))
	resp.Body.Close()
	got := "none"
	if resp.StatusCode == http.StatusOK {
		got = takeCopyAccounts(theirs)
	}
	resp, err = c.do(ctx, http.MethodPut, "/copy/v2/sync/accounts", map[string]string{"Content-Type": "application/json"}, marshalLocalCopyAccounts())
	if err != nil {
		return got, err
	}
	resp.Body.Close()
	return got, nil
}
