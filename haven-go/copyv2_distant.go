//go:build !(js && wasm)

package main

// The distant posts hand-off (discovery engine, design B): an owner's own
// devices get the posts their Haven fetched from each account's distant
// connections (distant_posts_job.go) during the catch-up
// (docs/MESH_COPY_V2_CONTRACT.md §6.6). Like the trust rank copy it rides
// the copy token, bound to a paired device's mesh key; the account key is
// never used or asked for, and nothing is signed. The device checks every
// note (id, signature, feed kind, author among the account's distant
// connections in its own rank copy) and keeps it in its feed store.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/trustrank"
)

const (
	copyDistantMaxEvents = 2000
	copyDistantMaxBytes  = 8 << 20
	copyDistantMark      = "#distant:"
	copyDistantRoundHdr  = "X-Distant-Round"
)

// distantRounds: when the job last stored new notes for each account, in
// memory. A note's created_at says nothing about when the Haven fetched
// it (the job may run hours late), so the device asks by this, not by
// time. After a restart every account reads as distantBoot: each device
// takes the whole window once.
var (
	distantRoundsMu sync.Mutex
	distantRounds   = map[string]int64{}
	distantBoot     = time.Now().UnixNano()
)

// distantRoundStored records that a round stored new notes for account.
func distantRoundStored(account string) {
	distantRoundsMu.Lock()
	distantRounds[account] = max(time.Now().UnixNano(), distantRounds[account]+1)
	distantRoundsMu.Unlock()
}

// distantRoundTag: what the answer for account is now. It changes when a
// round stores new notes, when the pick changes (builtAt) and after a
// restart. Never 0, which the device uses for "none yet".
func distantRoundTag(account string, builtAt int64) int64 {
	distantRoundsMu.Lock()
	round, ok := distantRounds[account]
	distantRoundsMu.Unlock()
	if !ok {
		round = distantBoot
	}
	h := fnv.New64a()
	fmt.Fprintf(h, "%d|%d", round, builtAt)
	return max(int64(h.Sum64()>>1), 1)
}

// serveSyncDistant is GET /copy/v2/sync/distant?account=<hex>&round=<tag>,
// behind the device's bearer. 204 when round is the answer's current tag;
// else 200, the tag in X-Distant-Round, and JSONL of the feed store's
// notes by account's distant connections in the feed window, kind 5 first,
// then newest first. 404: not an account this Haven ranks, or no result yet.
func (s *copyServer) serveSyncDistant(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || feedDB == nil {
		http.NotFound(w, r)
		return
	}
	q := r.URL.Query()
	account := q.Get("account")
	if !copyIsHex(account, 64) || !slices.Contains(trustRankAccounts(), account) {
		http.NotFound(w, r)
		return
	}
	dir := trustRankDir()
	built, err := trustrank.ResultBuiltAt(dir, account)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	authors := distantAuthors(dir, account)
	if authors == nil {
		http.NotFound(w, r)
		return
	}
	// Read the tag before the store: a round that ends after this changes
	// the tag, so the device asks again.
	tag := distantRoundTag(account, built)
	if round, _ := strconv.ParseInt(q.Get("round"), 10, 64); round == tag {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	since := distantSince(time.Now())
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set(copyDistantRoundHdr, strconv.FormatInt(tag, 10))
	if len(authors) == 0 {
		w.WriteHeader(http.StatusOK)
		return
	}
	ts := nostr.Timestamp(since)
	wdb := eventstore.RelayWrapper{Store: feedDB}
	evs, err := wdb.QuerySync(r.Context(), nostr.Filter{Kinds: feedPullKinds(), Authors: authors, Since: &ts, Limit: copyDistantMaxEvents})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// A device that stores a note before its deletion would keep it.
	slices.SortStableFunc(evs, func(a, b *nostr.Event) int {
		if (a.Kind == nostr.KindDeletion) != (b.Kind == nostr.KindDeletion) {
			if a.Kind == nostr.KindDeletion {
				return -1
			}
			return 1
		}
		return int(b.CreatedAt) - int(a.CreatedAt)
	})
	w.WriteHeader(http.StatusOK)
	written := 0
	for _, ev := range evs {
		line, err := json.Marshal(ev)
		if err != nil {
			continue
		}
		if written+len(line)+1 > copyDistantMaxBytes {
			break
		}
		if _, err := w.Write(append(line, '\n')); err != nil {
			return
		}
		written += len(line) + 1
	}
}

// syncDistant asks A for each own account's distant posts and keeps the
// ones that pass. It never fails the catch-up: an A from before this
// answers 404. Returns how many notes were new.
func (c *copyClient) syncDistant(ctx context.Context) int {
	if !trustRankTakesCopy() || feedDB == nil {
		return 0
	}
	dir, got := copyTrustKeepDir(), 0
	for _, account := range trustRankAccounts() {
		// The device's own copy, which syncTrust just brought up to date:
		// the same pick the Haven made from the same file.
		authors := distantAuthors(dir, account)
		if len(authors) == 0 {
			continue
		}
		mark := c.peer + copyDistantMark + account
		copySyncMu.Lock()
		last := loadCopySync()[copyPeerKey(mark)]
		copySyncMu.Unlock()
		n, tag, ok := c.fetchDistant(ctx, account, last, authors)
		got += n
		if !ok {
			if ctx.Err() != nil {
				return got
			}
			continue
		}
		if tag != 0 && tag != last {
			markCopySynced(mark, tag)
		}
		if n > 0 {
			slog.Info("distant posts kept", "account", account[:8], "new", n)
		}
	}
	return got
}

// fetchDistant reads one account's JSONL from A, sending the tag of the
// last whole answer (0: none). tag is the new answer's tag; a 204 (nothing
// changed) is ok with tag 0. ok: the whole answer was read (a 404 or a cut
// body is not ok, so the next catch-up asks again).
func (c *copyClient) fetchDistant(ctx context.Context, account string, last int64, authors []string) (got int, tag int64, ok bool) {
	path := "/copy/v2/sync/distant?account=" + account
	if last != 0 {
		path += "&round=" + strconv.FormatInt(last, 10)
	}
	resp, err := c.do(ctx, http.MethodGet, path, nil, nil)
	if err != nil {
		return 0, 0, false
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return 0, 0, true
	}
	if resp.StatusCode != http.StatusOK {
		return 0, 0, false
	}
	tag, _ = strconv.ParseInt(resp.Header.Get(copyDistantRoundHdr), 10, 64)
	allowed := make(map[string]bool, len(authors))
	for _, pk := range authors {
		allowed[pk] = true
	}
	got, ok = keepDistantLines(ctx, io.LimitReader(resp.Body, copyDistantMaxBytes+1), allowed)
	return got, tag, ok
}

// keepDistantLines stores each line that is a feed note by an allowed
// author through importOne (id, signature, deletions). ok is false when
// the body was cut, too long or had more than copyDistantMaxEvents lines.
func keepDistantLines(ctx context.Context, body io.Reader, allowed map[string]bool) (got int, ok bool) {
	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	read, lines, now := 0, 0, time.Now()
	for sc.Scan() {
		lines++
		read += len(sc.Bytes()) + 1
		if lines > copyDistantMaxEvents || read > copyDistantMaxBytes {
			return got, false
		}
		var ev nostr.Event
		if json.Unmarshal(sc.Bytes(), &ev) != nil || !allowed[ev.PubKey] || !slices.Contains(feedPullKinds(), ev.Kind) {
			continue
		}
		if importOne(ctx, feedDB, &ev, now) == restoreStored {
			got++
		}
	}
	return got, sc.Err() == nil
}
