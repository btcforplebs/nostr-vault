//go:build !(js && wasm)

package main

// Mesh vault copy v2, B's side: the copy_from job (docs/MESH_COPY_V2_CONTRACT.md §3).

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/spf13/afero"
)

// copyInDir holds B's copies in progress, one directory per peer.
const copyInDir = "copyin"

// copyPeersFile: per peer, the copy token B was given (0600).
const copyPeersFile = "copy_peers.json"

// copyHeadroom: B keeps this much free beyond the parts and what they restore to.
const copyHeadroom = 1 << 30

// copyBuildWait bounds how long B waits for A to finish building.
var copyBuildWait = 30 * time.Minute

// copyPollEvery: how often B asks while A builds. Shorter in tests.
var copyPollEvery = 2 * time.Second

// copyError is a contract error code (errors-v2.json).
// Bytes, when set, rides the failed line (needs_space: free/need).
type copyError struct {
	Code  string
	Bytes [2]int64
}

func (e *copyError) Error() string { return e.Code }

func copyErr(code string) error { return &copyError{Code: code} }

// copyErrorCode: the code an error carries, else "unreachable" (no answer).
func copyErrorCode(err error) string {
	var ce *copyError
	if errors.As(err, &ce) {
		return ce.Code
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	return "unreachable"
}

// copyClient is one B fetching from one A, through base (the loopback
// address the app's mesh gives A's own-device port).
type copyClient struct {
	peer  string
	base  string
	http  *http.Client
	dir   string
	token string
	// relays runs the setup relay import job after the restore; nil skips it.
	relays func() int
	// syncDB: the store the catch-up uses; copySyncDB unless a test sets it.
	syncDB func(string) DBBackend
	// freeBytes, swapped in tests.
	free func(string) (uint64, bool)
}

var copyPeersMu sync.Mutex

func copyPeerKey(peer string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(peer))))
	return hex.EncodeToString(sum[:8])
}

func loadCopyPeers() map[string]string {
	out := map[string]string{}
	if raw, err := os.ReadFile(copyPeersFile); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

func saveCopyPeerToken(peer, token string) {
	copyPeersMu.Lock()
	defer copyPeersMu.Unlock()
	peers := loadCopyPeers()
	peers[copyPeerKey(peer)] = token
	raw, _ := json.Marshal(peers)
	tmp := copyPeersFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copyPeersFile)
	}
}

func copyPeerToken(peer string) string {
	copyPeersMu.Lock()
	defer copyPeersMu.Unlock()
	return loadCopyPeers()[copyPeerKey(peer)]
}

func newCopyClient(peer, base string) *copyClient {
	return &copyClient{
		peer: peer,
		base: strings.TrimRight(base, "/"),
		http: &http.Client{Timeout: 90 * time.Second},
		dir:  filepath.Join(copyInDir, copyPeerKey(peer)),
		free: freeBytes,
	}
}

func (c *copyClient) line(l copyLine) {
	if l.Part == "" {
		l.Part = "-"
	}
	if l.Source == "" {
		l.Source = "mesh"
	}
	log.Println(formatCopyLine(l))
}

func (c *copyClient) statePath(id string) string {
	return filepath.Join(c.dir, "copy-"+id+".state.json")
}

func (c *copyClient) loadState() *copyState {
	entries, _ := os.ReadDir(c.dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".state.json") {
			var st copyState
			if raw, err := os.ReadFile(filepath.Join(c.dir, e.Name())); err == nil && json.Unmarshal(raw, &st) == nil && st.V == 1 {
				return &st
			}
		}
	}
	return nil
}

func (c *copyClient) saveState(st *copyState) error {
	raw, _ := json.Marshal(st)
	tmp := c.statePath(st.ID) + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.statePath(st.ID))
}

func (c *copyClient) do(ctx context.Context, method, path string, header map[string]string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	return c.http.Do(req)
}

// statusError maps A's answer to a contract code.
func statusError(code int) error {
	switch code {
	case http.StatusUnauthorized:
		return copyErr("auth_refused")
	case http.StatusForbidden:
		return copyErr("not_owner")
	case http.StatusNotFound:
		return copyErr("not_found")
	case http.StatusConflict:
		return copyErr("building")
	case http.StatusRequestedRangeNotSatisfiable:
		return copyErr("range")
	}
	return fmt.Errorf("HTTP %d", code)
}

// start asks A for a copy with the owner's signed NIP-98 (startAuth, base64
// of the kind 27235 event, without the "Nostr " prefix).
func (c *copyClient) start(ctx context.Context, startAuth string) (string, error) {
	c.token = ""
	resp, err := c.do(ctx, http.MethodPost, "/copy/v2/start", map[string]string{"Authorization": "Nostr " + startAuth}, nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", statusError(resp.StatusCode)
	}
	var out struct{ ID, Token, State string }
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out); err != nil || !copyIsHex(out.Token, 64) || !copyIsHex(out.ID, 32) {
		return "", copyErr("bad_manifest")
	}
	c.token = out.Token
	saveCopyPeerToken(c.peer, out.Token)
	return out.ID, nil
}

func (c *copyClient) manifest(ctx context.Context, id string) (copyManifest, error) {
	var m copyManifest
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/"+id, nil, nil)
	if err != nil {
		return m, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return m, statusError(resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<20)).Decode(&m); err != nil {
		return m, copyErr("bad_manifest")
	}
	// The id names B's state file: only A's own answer for this id is taken.
	if m.ID != id {
		return m, copyErr("bad_manifest")
	}
	return m, nil
}

// waitReady polls until A's copy is ready, and checks it (manifest-v2-cases).
func (c *copyClient) waitReady(ctx context.Context, id string) (copyManifest, error) {
	deadline := time.Now().Add(copyBuildWait)
	for {
		m, err := c.manifest(ctx, id)
		if err != nil {
			return m, err
		}
		if m.State == "building" {
			c.line(copyLine{Stage: "building", Items: [2]int64{int64(m.Progress.StoresDone + m.Progress.FilesDone), int64(m.Progress.StoresTotal + m.Progress.FilesTotal)}})
			if time.Now().After(deadline) {
				return m, copyErr("unreachable")
			}
			select {
			case <-ctx.Done():
				return m, ctx.Err()
			case <-time.After(copyPollEvery):
			}
			continue
		}
		if why := copyManifestError(m, config.OwnerPubKey, whitelist()); why != "" {
			return m, copyErr(why)
		}
		return m, nil
	}
}

// fetchChunk gets chunk i of part and checks it.
func (c *copyClient) fetchChunk(ctx context.Context, id string, p copyPart, i int) ([]byte, error) {
	a := int64(i) * p.Chunk
	b := min(a+p.Chunk, p.Size) - 1
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/"+id+"/"+p.Name, map[string]string{"Range": fmt.Sprintf("bytes=%d-%d", a, b)}, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return nil, statusError(resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, p.Chunk+1))
	if err != nil {
		return nil, err
	}
	return data, nil
}

// fetchPart fills <part>.partial with every chunk st lacks, checking each,
// then checks the whole part; a whole-part mismatch is fetched once more.
func (c *copyClient) fetchPart(ctx context.Context, m copyManifest, p copyPart, st *copyState) (string, error) {
	partial := filepath.Join(c.dir, p.Name+".zip.partial")
	whole := filepath.Join(c.dir, p.Name+".zip")
	for attempt := 0; attempt < 2; attempt++ {
		f, err := os.OpenFile(partial, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return "", err
		}
		if err := f.Truncate(p.Size); err != nil {
			f.Close()
			return "", err
		}
		_, need := copyPlan(copyManifest{Parts: []copyPart{p}, ZipKey: st.ZipKey}, st)
		var got int64 = int64(len(p.Chunks)-len(need[p.Name])) * p.Chunk
		for _, i := range need[p.Name] {
			for {
				data, err := c.fetchChunk(ctx, m.ID, p, i)
				if err != nil {
					f.Close()
					return "", err
				}
				sum := sha256.Sum256(data)
				if hex.EncodeToString(sum[:]) == p.Chunks[i] {
					if _, err := f.WriteAt(data, int64(i)*p.Chunk); err != nil {
						f.Close()
						return "", err
					}
					st.Done[p.Name] = append(st.Done[p.Name], i)
					got += int64(len(data))
					if err := c.saveState(st); err != nil {
						f.Close()
						return "", err
					}
					break
				}
				key := fmt.Sprintf("%s:%d", p.Name, i)
				n, stop := copyChunkFailed(st.Failures[key])
				st.Failures[key] = n
				_ = c.saveState(st)
				slog.Warn("copy: chunk failed its hash", "part", p.Name, "chunk", i, "failures", n)
				if stop {
					f.Close()
					return "", copyErr("hash_mismatch")
				}
			}
			c.line(copyLine{Stage: "fetching", Part: p.Name, Bytes: [2]int64{min(got, p.Size), p.Size}, Items: [2]int64{int64(len(st.Done[p.Name])), int64(len(p.Chunks))}})
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return "", err
		}
		f.Close()
		sum, _, err := copyFileHash(partial)
		if err != nil {
			return "", err
		}
		if sum == p.SHA256 {
			return whole, os.Rename(partial, whole)
		}
		slog.Warn("copy: part failed its whole hash, fetching it again", "part", p.Name)
		st.Done[p.Name] = nil
		_ = c.saveState(st)
	}
	return "", copyErr("hash_mismatch")
}

// copyRestoreStats: what the restore put in, for the Done screen.
type copyRestoreStats struct {
	notes, messages, files int
}

// restoreNotes restores every store but the blob index (whose records go in
// only with their files), and leaves the checked settings for the app.
// Returns the settings state: "included", "none" or "refused", and the
// stores not fully restored here: one that could not be read to the end, or
// held events this vault failed to write. A re-run stores what is missing
// (everything dedupes by id), so the run keeps the copy as partial for it.
// ctx carries the restore's keys (withRestoreKeys): the run has already
// checked the zip's accounts.
func restoreCopyNotes(ctx context.Context, path string, stats *copyRestoreStats) (settings string, failed []string, err error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		return "", nil, err
	}
	defer zr.Close()
	var total importStats
	known := 0
	settings = "none"
	for _, file := range zr.File {
		if file.Name == "settings.json" {
			settings = applyCopySettings(file)
			continue
		}
		name, ok := strings.CutSuffix(file.Name, ".jsonl")
		if !ok || name == "blossom" {
			continue
		}
		db, ok := dbs[name]
		if !ok {
			continue
		}
		known++
		st, err := importEntry(ctx, db, file)
		total.add(st)
		switch name {
		case "outbox":
			stats.notes += st.stored + st.dup
		case "chat", "private":
			stats.messages += st.stored + st.dup
		}
		if err != nil || st.failed > 0 {
			slog.Error("copy: store not fully restored", "store", name, "failed", st.failed, "error", err)
			failed = append(failed, name)
		}
	}
	if known == 0 || total.stored+total.dup == 0 {
		return settings, failed, copyErr("nothing_restored")
	}
	return settings, failed, nil
}

// applyCopySettings checks the copied settings.json and, when it passes and
// is newer than B's own, writes it as copy-settings.json for the app.
func applyCopySettings(file *zip.File) string {
	rc, err := file.Open()
	if err != nil {
		return "none"
	}
	defer rc.Close()
	raw, err := io.ReadAll(io.LimitReader(rc, 1<<20))
	if err != nil {
		return "none"
	}
	return storeCopySettings(raw)
}

// storeCopySettings: the one place settings from another device go in.
func storeCopySettings(raw []byte) string {
	if why := copySettingsRefusal(raw, time.Now()); why != "" {
		slog.Warn("copy: settings refused", "reason", why)
		return "refused"
	}
	var theirs copySettings
	_ = json.Unmarshal(raw, &theirs)
	if !copySettingsNewer(localCopySettingsStamp(), theirs.UpdatedAt) {
		return "included"
	}
	tmp := copySettingsFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return "none"
	}
	if err := os.Rename(tmp, copySettingsFile); err != nil {
		return "none"
	}
	return "included"
}

// localCopySettingsStamp: updated_at of this device's own settings file, 0 for none.
func localCopySettingsStamp() int64 {
	raw, err := os.ReadFile(copySettingsFile)
	if err != nil {
		return 0
	}
	var s copySettings
	if json.Unmarshal(raw, &s) != nil {
		return 0
	}
	return s.UpdatedAt
}

// storeCopyBlob writes one file under its hash, checked as it streams; a
// file already here is kept. False when the bytes don't match the name.
func storeCopyBlob(sha string, r io.Reader) (bool, error) {
	if !isBlobHash(sha) {
		return false, nil
	}
	if copyBlobFile(sha) != "" {
		return true, nil
	}
	// A temp file of its own: the catch-up runs on every reconnect and can
	// overlap an upload or Import media of the same blob (writeBlobFile).
	return writeBlobFile(afero.NewOsFs(), sha, r)
}

// copyMediaResult: what restoreCopyMedia could not finish. failed: files
// or blob records this vault failed to write, which a re-run can store.
// leftOut: files that came damaged (an entry that can't be read, or bytes
// that don't match the name). The parts passed their hashes, so the same
// zip brings them damaged again; the catch-up asks A for them once more.
type copyMediaResult struct {
	failed, leftOut int
}

// restoreCopyMedia stores each file of media.zip, then the blob records of
// the files that are now here (from notes.zip's blossom.jsonl). A file that
// fails is counted and the rest go on.
func restoreCopyMedia(ctx context.Context, mediaPath, notesPath string, stats *copyRestoreStats, progress func(done, total int)) (copyMediaResult, error) {
	var res copyMediaResult
	have := map[string]bool{}
	if mediaPath != "" {
		zr, err := zip.OpenReader(mediaPath)
		if err != nil {
			return res, err
		}
		total := len(zr.File)
		for i, file := range zr.File {
			if ctx.Err() != nil {
				zr.Close()
				return res, ctx.Err()
			}
			sha, ok := strings.CutPrefix(file.Name, "media/")
			if !ok {
				continue
			}
			rc, err := file.Open()
			if err != nil {
				slog.Warn("copy: file could not be read from the copy, left out", "sha256", sha, "error", err)
				res.leftOut++
				continue
			}
			ok, err = storeCopyBlob(sha, rc)
			rc.Close()
			switch {
			case err != nil:
				slog.Error("copy: file not stored", "sha256", sha, "error", err)
				res.failed++
			case ok:
				have[sha] = true
				stats.files++
			default:
				slog.Warn("copy: file did not match its hash, left out", "sha256", sha)
				res.leftOut++
			}
			progress(i+1, total)
		}
		zr.Close()
	}
	if blossomDB == nil {
		return res, nil
	}
	zr, err := zip.OpenReader(notesPath)
	if err != nil {
		return res, err
	}
	defer zr.Close()
	for _, file := range zr.File {
		if file.Name != "blossom.jsonl" {
			continue
		}
		rc, err := file.Open()
		if err != nil {
			return res, err
		}
		var kept bytes.Buffer
		dec := json.NewDecoder(rc)
		for dec.More() {
			var rec struct {
				Tags [][]string `json:"tags"`
			}
			var raw json.RawMessage
			if err := dec.Decode(&raw); err != nil {
				break
			}
			if json.Unmarshal(raw, &rec) == nil && len(rec.Tags) > 0 && len(rec.Tags[0]) == 2 && rec.Tags[0][0] == "x" && have[rec.Tags[0][1]] {
				kept.Write(raw)
				kept.WriteByte('\n')
			}
		}
		rc.Close()
		st, err := importDBStats(ctx, blossomDB, &kept)
		if err != nil || st.failed > 0 {
			slog.Error("copy: blob records not fully restored", "failed", st.failed, "error", err)
			res.failed += max(st.failed, 1)
		}
	}
	return res, nil
}

// run is the whole copy: resume or start, fetch, restore, relays, done.
// startAuth may be "" when resuming a copy whose token B still holds.
func (c *copyClient) run(ctx context.Context, startAuth string) (err error) {
	defer func() {
		if err != nil {
			l := copyLine{Stage: "failed", Error: copyErrorCode(err)}
			var ce *copyError
			if errors.As(err, &ce) {
				l.Bytes = ce.Bytes
			}
			c.line(l)
		}
	}()
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return err
	}
	st := c.loadState()
	c.token = copyPeerToken(c.peer)
	if st != nil && c.token == "" {
		// A state with no token to read its copy with is no use: start over.
		_ = os.RemoveAll(c.dir)
		_ = os.MkdirAll(c.dir, 0o700)
		st = nil
	}
	var m copyManifest
	if st != nil {
		m, err = c.waitReady(ctx, st.ID)
		if code := copyErrorCode(err); code == "not_found" || code == "auth_refused" {
			// A's copy expired, or a new token is needed: start over.
			_ = os.RemoveAll(c.dir)
			_ = os.MkdirAll(c.dir, 0o700)
			st, err = nil, nil
		} else if err != nil {
			return err
		}
	}
	if st == nil {
		if startAuth == "" {
			return copyErr("auth_refused")
		}
		id, err := c.start(ctx, startAuth)
		if err != nil {
			return err
		}
		if m, err = c.waitReady(ctx, id); err != nil {
			return err
		}
	}
	restart, _ := copyPlan(m, st)
	if st == nil || restart {
		for _, n := range []string{"notes", "media"} {
			_ = os.Remove(filepath.Join(c.dir, n+".zip.partial"))
			_ = os.Remove(filepath.Join(c.dir, n+".zip"))
		}
		if st != nil {
			_ = os.Remove(c.statePath(st.ID))
		}
		st = &copyState{V: 1, ID: m.ID, ZipKey: m.ZipKey, Done: map[string][]int{}, Failures: map[string]int{}}
		if err := c.saveState(st); err != nil {
			return err
		}
	}

	// Disk: the parts as received, about as much again restored, and 1 GB.
	var partBytes int64
	for _, p := range m.Parts {
		partBytes += p.Size
	}
	if free, ok := c.free(c.dir); ok && free < uint64(2*partBytes+copyHeadroom) {
		slog.Warn("copy: not enough space", "need", 2*partBytes+copyHeadroom, "free", free)
		return &copyError{Code: "needs_space", Bytes: [2]int64{int64(free), 2*partBytes + copyHeadroom}}
	}

	paths := map[string]string{}
	for _, p := range m.Parts {
		whole := filepath.Join(c.dir, p.Name+".zip")
		if sum, _, err := copyFileHash(whole); err == nil && sum == p.SHA256 {
			paths[p.Name] = whole
			continue
		}
		path, err := c.fetchPart(ctx, m, p, st)
		if err != nil {
			return err
		}
		paths[p.Name] = path
	}

	var stats copyRestoreStats
	c.line(copyLine{Stage: "restoring", Part: "notes", Bytes: [2]int64{0, partSize(m, "notes")}})
	// §3.4 (Logen, 2026-11-06): the copy keeps every event it carries, for
	// every account in its list, but adds no account. The list goes to the
	// app (copy-accounts.json), which asks the person and calls AddAccountsC
	// for the ones they tick; their notes are already here.
	theirs, has, err := checkZipAccounts(paths["notes"])
	if err != nil {
		if errors.Is(err, errNotYourBackup) {
			return copyErr("wrong_owner")
		}
		if errors.Is(err, errAccountsRefused) {
			return copyErr("bad_manifest")
		}
		return err
	}
	rctx := ctx
	if has {
		// The keep list (copyKeepEntry): every account whose notes A holds.
		// Every account B doesn't own, named in accounts.json or only in the
		// keep list (or an older A's accounts.json alone), is recorded as
		// brought over before the first event goes in, so it is read only
		// from the start; a failed record stops the copy. None is added here.
		keep, err := checkZipKeep(paths["notes"])
		if err != nil {
			if errors.Is(err, errAccountsRefused) {
				return copyErr("bad_manifest")
			}
			return err
		}
		brought := copyAccountList{V: 1, Accounts: append(slices.Clone(theirs.Accounts), keepOnly(keep, theirs).Accounts...)}
		if err := recordBroughtAccounts(brought); err != nil {
			return err
		}
		rctx = withRestoreKeys(ctx, append(theirs.hexes(), keep...))
	}
	settings, failedStores, err := restoreCopyNotes(rctx, paths["notes"], &stats)
	if err != nil {
		return err
	}
	c.line(copyLine{Stage: "restoring", Part: "media", Items: [2]int64{0, int64(m.Files.Count)}})
	media, err := restoreCopyMedia(rctx, paths["media"], paths["notes"], &stats, func(done, total int) {
		if done%25 == 0 || done == total {
			c.line(copyLine{Stage: "restoring", Part: "media", Items: [2]int64{int64(done), int64(total)}})
		}
	})
	if err != nil {
		return err
	}
	if ctx.Err() != nil {
		// Stopped mid-restore: the state stays for a resume (cancelled).
		return ctx.Err()
	}
	if has {
		// Offered to the person, never added here (§3.4).
		offerCopyAccounts(theirs)
	}
	// Something this vault failed to write: not done. Both zips, the parts
	// and the state stay, A is not told, and the peer is not marked synced,
	// so the next attempt restores again from the parts here (it dedupes)
	// and stores what is missing (§3.2 partial).
	if len(failedStores) > 0 || media.failed > 0 {
		st.Partial = slices.Clone(failedStores)
		if media.failed > 0 {
			st.Partial = append(st.Partial, fmt.Sprintf("files:%d", media.failed))
		}
		_ = c.saveState(st)
		slog.Warn("copy: partial, kept for the next attempt", "stores", failedStores, "files_failed", media.failed)
		return copyErr("partial")
	}
	st.Restored = []string{"notes", "media"}
	st.Partial = nil
	_ = c.saveState(st)

	// A deletes its zip once B has everything (pick 5).
	if resp, err := c.do(ctx, http.MethodPost, "/copy/v2/"+m.ID+"/done", nil, nil); err == nil {
		resp.Body.Close()
	}
	_ = os.RemoveAll(c.dir)
	// Files that came damaged, or that the manifest counts but media.zip
	// lacks, are not here. The zip can't bring them, so the copy is done,
	// but the peer is not marked synced: the first catch-up then compares
	// everything and asks A for each missing own file again.
	leftOut := media.leftOut
	if missing := m.Files.Count - stats.files - media.failed - media.leftOut; missing > 0 {
		leftOut += missing
	}
	if leftOut == 0 {
		markCopySynced(c.peer, m.CreatedAt)
	} else {
		slog.Warn("copy: files left out, the catch-up asks for them again", "files", leftOut)
	}

	if c.relays != nil {
		c.line(copyLine{Stage: "relays", Source: "relays"})
		c.relays()
	}
	done := copyLine{Stage: "done", Items: [2]int64{int64(stats.notes + stats.messages + stats.files), int64(stats.notes + stats.messages + stats.files)}}
	if settings == "refused" || m.Settings == "refused" {
		done.Error = "settings_refused"
	}
	log.Printf("%s notes=%d messages=%d files=%d left_out=%d", formatCopyLine(done), stats.notes, stats.messages, stats.files, leftOut)
	return nil
}

func partSize(m copyManifest, name string) int64 {
	if i := slices.IndexFunc(m.Parts, func(p copyPart) bool { return p.Name == name }); i >= 0 {
		return m.Parts[i].Size
	}
	return 0
}

// copyRunner: one copy or catch-up at a time per process.
type copyRunner struct {
	mu      sync.Mutex
	running bool
	cancel  context.CancelFunc
}

var copyRuns copyRunner

// begin starts fn on spawn unless one is running: 0 started, runBusy otherwise.
func (r *copyRunner) begin(ctx context.Context, spawn func(string, func()), name string, fn func(context.Context)) int {
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return runBusy
	}
	cctx, cancel := context.WithCancel(ctx)
	r.running, r.cancel = true, cancel
	r.mu.Unlock()
	spawn(name, func() {
		defer func() {
			r.mu.Lock()
			r.running, r.cancel = false, nil
			r.mu.Unlock()
			cancel()
		}()
		fn(cctx)
	})
	return 0
}

// stop cancels what runs: 0 cancelling, 1 nothing running.
func (r *copyRunner) stop() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.running || r.cancel == nil {
		return 1
	}
	r.cancel()
	return 0
}

// startCopyFrom is StartCopyFromC: the first copy from peer through base,
// then the relay setup job (waited for, so Done comes after it).
func startCopyFrom(ctx context.Context, spawn func(string, func()), peer, base, startAuth string) int {
	return copyRuns.begin(ctx, spawn, "copyv2.copyFrom", func(cctx context.Context) {
		c := newCopyClient(peer, base)
		c.relays = func() int {
			rc := importJobsRunner.run(ctx, spawn, jobSetup, false)
			if rc == 0 {
				importJobsRunner.wait()
			}
			return rc
		}
		if err := c.run(cctx, startAuth); err != nil {
			slog.Warn("copy from peer stopped", "error", copyErrorCode(err))
		}
	})
}

// startCopySync is CopySyncC: one catch-up with peer through base.
func startCopySync(ctx context.Context, spawn func(string, func()), peer, base string) int {
	return copyRuns.begin(ctx, spawn, "copyv2.sync", func(cctx context.Context) {
		if _, err := newCopyClient(peer, base).sync(cctx); err != nil {
			slog.Warn("copy catch-up stopped", "error", copyErrorCode(err))
		}
	})
}

// startCopyFromEnv is havend as B: the box starts the engine with COPY_FROM
// (A's mesh npub), COPY_BASE (the loopback base nv-mesh gives A's own-device
// port) and COPY_START_AUTH (the owner-signed kind 27235 for the start, from
// the owner's app; empty = resume with the token already held). Unset
// COPY_FROM: nothing to do.
func startCopyFromEnv(ctx context.Context, getenv func(string) string, spawn func(string, func())) int {
	peer, base := getenv("COPY_FROM"), getenv("COPY_BASE")
	if peer == "" || base == "" {
		return 1
	}
	return startCopyFrom(ctx, spawn, peer, base, getenv("COPY_START_AUTH"))
}
