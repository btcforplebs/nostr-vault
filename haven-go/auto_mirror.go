//go:build !(js && wasm)

package main

// Auto-Mirror in the engine (One Vault spec E6, Logen 2026-11-21: "auto-mirror
// on boxes = yes"). On the phones and the Mac it is app code (iOS
// AutoMirrorLedger.swift + MirrorService, Android AutoMirrorRules.kt); a box
// has no app, so the engine runs it. It copies into this vault the files your
// accounts keep on outside servers: first what each server in the account's
// kind 10063 lists for it, then the media links in the account's own notes.
//
// The rules the apps keep (Logen 2026-11-12, after an iPhone signed 1,093
// upload auths in half an hour and stored nothing new), and how a box keeps
// them:
//
//  1. Hash first. A file the vault holds is never downloaded: its hash is
//     known from the server's list, a hash-named link, the note's imeta x,
//     or the link remembered from an earlier run (auto-mirror-links.json).
//  2. One signature per run. A box holds no account key, so it signs
//     nothing at all: lists are read without auth (a server that wants it
//     is reported, not retried) and files go in through the engine itself
//     (storeAccountBlob), the way importOwnerBlob does for a keyless app.
//  3. At most one run per 3 hours, counted from when a run starts and kept
//     on disk, so a restart mid-run does not start another. A clock set
//     back does not hold it off for good.
//  4. At most 200 downloads per run; the rest come next run.
//
// The box (havend, internal/box/routes_media.go) talks to the job through
// two files in the vault folder, the engine's working directory, the same
// way it hands over copy-accounts.json: it writes auto-mirror.json (the
// switch, and "run now"), the engine writes auto-mirror-state.json. Nothing
// else writes auto-mirror.json, so a Mac or phone engine never runs this.
//
// Accounts: the owner and each signed-in account (localCopyAccounts, which
// the box writes on every start). Watch-only accounts are never mirrored.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

const (
	autoMirrorEvery     = 3 * time.Hour
	autoMirrorMaxPerRun = 200
	// autoMirrorLinksMax: links remembered; the oldest go first.
	autoMirrorLinksMax = 20_000
	// autoMirrorParallel: downloads at once (the apps use four).
	autoMirrorParallel = 4
	// autoMirrorNotePage: notes per local page; autoMirrorNotePages caps how
	// far back one run reads (the store may answer fewer than asked).
	autoMirrorNotePage  = 500
	autoMirrorNotePages = 400
	// autoMirrorHeadroom: free space kept on the vault's disk.
	autoMirrorHeadroom = 512 << 20

	autoMirrorSettingsFile = "auto-mirror.json"
	autoMirrorStateFile    = "auto-mirror-state.json"
	autoMirrorLinksFile    = "auto-mirror-links.json"
)

// autoMirrorSettings is what the box writes.
type autoMirrorSettings struct {
	Enabled bool `json:"enabled"`
	// RunNowAt: a "run now" asked at this unix second. Handled once
	// (autoMirrorState.HandledRunNow), and it skips the 3 hour wait.
	RunNowAt int64 `json:"run_now_at,omitempty"`
}

// autoMirrorResult is what one run did.
type autoMirrorResult struct {
	Saved       int      `json:"saved"`
	Skipped     int      `json:"skipped"`
	Unreachable []string `json:"unreachable,omitempty"` // server hosts whose list could not be read
	CapReached  bool     `json:"cap_reached,omitempty"`
	Error       string   `json:"error,omitempty"`
}

// autoMirrorState is what the engine writes.
type autoMirrorState struct {
	Running       bool              `json:"running"`
	LastStart     int64             `json:"last_start,omitempty"`
	LastFinish    int64             `json:"last_finish,omitempty"`
	HandledRunNow int64             `json:"handled_run_now,omitempty"`
	Last          *autoMirrorResult `json:"last,omitempty"`
}

// autoMirrorDue: whether a run may start, given the last run's start (0:
// never). A clock set back does not hold it off for good.
func autoMirrorDue(lastStart, now int64) bool {
	return lastStart == 0 || now < lastStart || time.Duration(now-lastStart)*time.Second >= autoMirrorEvery
}

// autoMirrorShouldRun decides one tick: run, and whether it answers a "run now".
func autoMirrorShouldRun(s autoMirrorSettings, st autoMirrorState, now int64) (run, runNow bool) {
	if !s.Enabled || st.Running {
		return false, false
	}
	if s.RunNowAt > st.HandledRunNow {
		return true, true
	}
	return autoMirrorDue(st.LastStart, now), false
}

// ── One run ────────────────────────────────────────────────────────────

// autoMirrorDeps is everything a run reaches outside itself; tests fake it.
type autoMirrorDeps struct {
	client   *http.Client
	accounts func() []string                                                                // hex
	servers  func(ctx context.Context, pubkey string) []string                              // the account's 10063, no trailing slash
	notes    func(ctx context.Context, pubkey string, until nostr.Timestamp) []*nostr.Event // newest first, kind 1
	stored   func(sha string) bool
	store    func(ctx context.Context, pubkey, file, sha, mimeType string) error
	// claim adds pubkey's record for a file already stored here (another
	// account's copy), so the file counts as this account's too (Copy to
	// servers offers only an account's own files). added: a new record.
	claim func(ctx context.Context, pubkey, sha string) (added bool, err error)
	// room: the most bytes one download may write (Tron #2386: the cap is
	// enforced while reading, not checked after the file is on disk).
	room    func() int64
	tempDir string
	links   *autoMirrorLinks
	log     func(msg string, args ...any)
}

type blobListEntry struct {
	SHA256 string `json:"sha256"`
	Type   string `json:"type"`
}

// job is one file to fetch.
type autoMirrorJob struct {
	pubkey string
	url    string
	sha    string // expected, "" when not known before the download
	link   bool   // a note link: remember what it served
}

// runAutoMirror runs the two steps for every account under one 200 cap.
func runAutoMirror(ctx context.Context, d autoMirrorDeps) autoMirrorResult {
	var res autoMirrorResult
	var jobs []autoMirrorJob
	picked := map[string]bool{} // hashes queued this run, across accounts and steps
	room := func() int { return autoMirrorMaxPerRun - len(jobs) }
	unreachable := map[string]bool{}
	var claimed int
	tried := map[string]bool{} // pubkey+sha claims tried this run
	// have: the file is stored here already, or queued this run. A stored
	// file is claimed for pk (its record added, nothing downloaded), even
	// when another account's copy is the one on disk.
	have := func(pk, sha string) bool {
		if !d.stored(sha) {
			return picked[sha]
		}
		if tried[pk+sha] {
			return true
		}
		tried[pk+sha] = true
		if added, err := d.claim(ctx, pk, sha); err != nil {
			d.log("auto-mirror: claim failed", "sha", sha, "err", err)
		} else if added {
			claimed++
		}
		return true
	}

	for _, pk := range d.accounts() {
		if room() <= 0 {
			break
		}
		// 1. Each server's list of this account's files.
		for _, server := range d.servers(ctx, pk) {
			if room() <= 0 {
				break
			}
			entries, err := fetchBlobList(ctx, d.client, server, pk)
			if err != nil {
				d.log("auto-mirror: list unreadable", "server", server, "err", err)
				unreachable[hostOf(server)] = true
				continue
			}
			for _, e := range entries {
				sha := strings.ToLower(e.SHA256)
				if !isBlobHash(sha) || have(pk, sha) {
					continue
				}
				if room() <= 0 {
					res.CapReached = true
					break
				}
				picked[sha] = true
				jobs = append(jobs, autoMirrorJob{pubkey: pk, url: server + "/" + sha, sha: sha})
			}
		}
		// 2. The media links in the account's own notes.
		if room() <= 0 {
			res.CapReached = true
			break
		}
		picker := newLinkPicker(func(sha string) bool { return have(pk, sha) })
		var until nostr.Timestamp
		edge := map[string]bool{}
	pages:
		for page := 0; page < autoMirrorNotePages; page++ {
			batch := d.notes(ctx, pk, until)
			fresh := 0
			oldest := until
			for _, ev := range batch {
				if ev.PubKey != pk || edge[ev.ID] || (until != 0 && ev.CreatedAt > until) {
					continue
				}
				fresh++
				if oldest == 0 || ev.CreatedAt < oldest {
					oldest = ev.CreatedAt
				}
				imeta := imetaHashes(ev.Tags)
				for _, link := range noteMediaLinks(ev) {
					if !picker.offer(link, func(u string) string {
						if h := imeta[u]; h != "" {
							return h
						}
						return d.links.hashFor(u)
					}) {
						continue
					}
					sha := blobHashOfURL(link)
					if sha == "" {
						sha = imeta[link]
					}
					if sha == "" {
						sha = d.links.hashFor(link)
					}
					if sha != "" {
						picked[sha] = true
					}
					jobs = append(jobs, autoMirrorJob{pubkey: pk, url: link, sha: sha, link: true})
					if room() <= 0 {
						res.CapReached = true
						break pages
					}
				}
			}
			if fresh == 0 {
				break
			}
			// until is inclusive: the notes at the oldest second come again.
			if oldest != until {
				edge = map[string]bool{}
			}
			for _, ev := range batch {
				if ev.CreatedAt == oldest {
					edge[ev.ID] = true
				}
			}
			until = oldest
		}
	}

	var saved, skipped atomic.Int64
	sem := make(chan struct{}, autoMirrorParallel)
	var wg sync.WaitGroup
	for _, j := range jobs {
		if ctx.Err() != nil {
			break
		}
		sem <- struct{}{}
		wg.Add(1)
		go func(j autoMirrorJob) {
			defer func() { <-sem; wg.Done() }()
			sha, err := fetchIntoVault(ctx, d, j)
			if err != nil {
				skipped.Add(1)
				d.log("auto-mirror: skipped", "url", j.url, "err", err)
				return
			}
			if j.link {
				d.links.remember(j.url, sha)
			}
			saved.Add(1)
		}(j)
	}
	wg.Wait()
	res.Saved = int(saved.Load()) + claimed
	res.Skipped = int(skipped.Load())
	for h := range unreachable {
		res.Unreachable = append(res.Unreachable, h)
	}
	slices.Sort(res.Unreachable)
	return res
}

func hostOf(server string) string {
	if u, err := url.Parse(server); err == nil && u.Host != "" {
		return u.Host
	}
	return server
}

// fetchBlobList reads GET <server>/list/<pubkey> without auth (BUD-02).
func fetchBlobList(ctx context.Context, c *http.Client, server, pubkey string) ([]blobListEntry, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, server+"/list/"+pubkey, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return nil, fmt.Errorf("HTTP %d: the server wants a signed list request, which a box cannot make", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var out []blobListEntry
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<20)).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

var errHashMismatch = errors.New("the file is not the one its hash names")

var errNoRoom = errors.New("the file is too big for one blob, or for the room left on the vault's disk")

// fetchIntoVault downloads one file to a temp file, checks it, and stores it
// as the account's. Returns the file's sha256.
func fetchIntoVault(ctx context.Context, d autoMirrorDeps, j autoMirrorJob) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, j.url, nil)
	if err != nil {
		return "", err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	limit := d.room()
	if limit <= 0 || resp.ContentLength > limit {
		return "", errNoRoom
	}
	ct := strings.TrimSpace(resp.Header.Get("Content-Type"))
	if ct == "" {
		ct = mime.TypeByExtension(path.Ext(j.url))
	}
	if mt, _, err := mime.ParseMediaType(ct); err == nil {
		ct = mt
	} else {
		ct = "application/octet-stream"
	}
	if !isRestorableBlobType(ct) {
		return "", fmt.Errorf("media type %q not allowed", ct)
	}
	tmp, err := os.CreateTemp(d.tempDir, ".auto-mirror-*.part")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	h := newSHA256()
	// One byte over the limit is how a body with no (or a false)
	// Content-Length is caught: at most limit+1 bytes ever reach the disk.
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(resp.Body, limit+1))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "", err
	}
	if n > limit {
		return "", errNoRoom
	}
	sha := h.hex()
	if j.sha != "" && sha != j.sha {
		return "", errHashMismatch
	}
	if err := d.store(ctx, j.pubkey, tmp.Name(), sha, ct); err != nil {
		return "", err
	}
	return sha, nil
}

// accountNotes: one page of pubkey's kind 1 notes, newest first, until
// (inclusive; 0 = now).
func accountNotes(ctx context.Context, pubkey string, until nostr.Timestamp) []*nostr.Event {
	if outboxDB == nil {
		return nil
	}
	qctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	f := nostr.Filter{Kinds: []int{1}, Authors: []string{pubkey}, Limit: autoMirrorNotePage}
	if until != 0 {
		u := until
		f.Until = &u
	}
	ch, err := outboxDB.QueryEvents(qctx, f)
	if err != nil {
		return nil
	}
	var out []*nostr.Event
	for ev := range ch {
		out = append(out, ev)
	}
	slices.SortFunc(out, func(a, b *nostr.Event) int { return int(b.CreatedAt) - int(a.CreatedAt) })
	return out
}

// vaultRoom: the most one download may write: the blob cap, and no more
// than its share (one of autoMirrorParallel) of the free space above the
// headroom, so the downloads running at once cannot fill the disk between
// them. Unknown free space: the blob cap alone.
func vaultRoom() int64 {
	return downloadRoom(freeBytes(config.BlossomPath))
}

func downloadRoom(free uint64, known bool) int64 {
	if !known {
		return maxBlobBytes
	}
	if free <= autoMirrorHeadroom {
		return 0
	}
	return min(int64(maxBlobBytes), int64((free-autoMirrorHeadroom)/autoMirrorParallel))
}

func liveAutoMirrorDeps() autoMirrorDeps {
	return autoMirrorDeps{
		client:   mediaJobsClient,
		accounts: ownSigningAccounts,
		servers:  accountServers,
		notes:    accountNotes,
		stored:   blobStoredHere,
		store:    storeAccountBlob,
		claim:    claimAccountBlob,
		room:     vaultRoom,
		tempDir:  config.BlossomPath,
		links:    loadAutoMirrorLinks(autoMirrorLinksFile),
		log: func(msg string, args ...any) {
			slog.Info(msg, args...)
		},
	}
}

// autoMirrorTick runs one check of the switch, and a run when one is due.
func autoMirrorTick(ctx context.Context, now func() time.Time, deps func() autoMirrorDeps) {
	var s autoMirrorSettings
	if !readJSONFile(autoMirrorSettingsFile, &s) {
		return
	}
	var st autoMirrorState
	readJSONFile(autoMirrorStateFile, &st)
	// A run cut short by a restart left running=true behind; this engine has none.
	st.Running = false
	run, runNow := autoMirrorShouldRun(s, st, now().Unix())
	if !run {
		return
	}
	// Rule 3: the start is on disk before anything is fetched.
	st.Running = true
	st.LastStart = now().Unix()
	if runNow {
		st.HandledRunNow = s.RunNowAt
	}
	writeJSONFile(autoMirrorStateFile, st)
	d := deps()
	res := runAutoMirror(ctx, d)
	if err := d.links.save(autoMirrorLinksFile); err != nil {
		slog.Warn("auto-mirror: could not save links", "err", err)
	}
	st.Running = false
	st.LastFinish = now().Unix()
	st.Last = &res
	writeJSONFile(autoMirrorStateFile, st)
	slog.Info("auto-mirror: run done", "saved", res.Saved, "skipped", res.Skipped, "unreachable", len(res.Unreachable), "cap", res.CapReached)
}

// autoMirrorTickEvery: how often the switch and "run now" are read.
var autoMirrorTickEvery = 30 * time.Second

// runAutoMirrorLoop checks every autoMirrorTickEvery until ctx ends. Only a
// box writes auto-mirror.json, so elsewhere each tick is one failed read.
func runAutoMirrorLoop(ctx context.Context) {
	t := time.NewTicker(autoMirrorTickEvery)
	defer t.Stop()
	for {
		autoMirrorTick(ctx, time.Now, liveAutoMirrorDeps)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
