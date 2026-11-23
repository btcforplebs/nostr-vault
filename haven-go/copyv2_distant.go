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
	"io"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

const (
	copyDistantMaxEvents = 2000
	copyDistantMaxBytes  = 8 << 20
	// copyDistantOverlap: a catch-up asks from two hours before the last
	// one, so notes the Haven fetched a round late still come over.
	copyDistantOverlap = 2 * time.Hour
	copyDistantMark    = "#distant:"
)

// serveSyncDistant is GET /copy/v2/sync/distant?account=<hex>&since=<unix>,
// behind the device's bearer: JSONL of the feed store's notes by account's
// distant connections at or after since, kind 5 first, then newest first.
// 404: not an account this Haven ranks, or no result yet.
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
	authors := distantAuthors(trustRankDir(), account)
	if authors == nil {
		http.NotFound(w, r)
		return
	}
	since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
	since = max(since, distantSince(time.Now()))
	w.Header().Set("Content-Type", "application/x-ndjson")
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
		started := time.Now()
		since := int64(0)
		if last > 0 {
			since = last - int64(copyDistantOverlap/time.Second)
		}
		n, ok := c.fetchDistant(ctx, account, since, authors)
		got += n
		if !ok {
			if ctx.Err() != nil {
				return got
			}
			continue
		}
		markCopySynced(mark, started.Unix())
		if n > 0 {
			slog.Info("distant posts kept", "account", account[:8], "new", n)
		}
	}
	return got
}

// fetchDistant reads one account's JSONL from A. ok: the whole answer was
// read (a 404 is not ok, so the next round asks again from the start).
func (c *copyClient) fetchDistant(ctx context.Context, account string, since int64, authors []string) (int, bool) {
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/distant?account="+account+"&since="+strconv.FormatInt(since, 10), nil, nil)
	if err != nil {
		return 0, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, false
	}
	allowed := make(map[string]bool, len(authors))
	for _, pk := range authors {
		allowed[pk] = true
	}
	return keepDistantLines(ctx, io.LimitReader(resp.Body, copyDistantMaxBytes+1), allowed)
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
