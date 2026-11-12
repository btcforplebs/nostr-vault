//go:build !(js && wasm)

package main

// Mesh vault copy v2, A's side: building the copy (docs/MESH_COPY_V2_CONTRACT.md §3).

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// copySettingsFile: the app's allowlisted settings (contract §5), in the
// engine's working dir. Written by the app on A; on B the engine writes the
// checked copy here for the app to apply.
const copySettingsFile = "copy-settings.json"

// copyCacheDir holds A's built copies, one directory per copy id.
const copyCacheDir = "copy"

// copyKeepFor: A deletes a copy this long after building it, done or not.
const copyKeepFor = 24 * time.Hour

var errCopyNoSpace = errors.New("no_space")

// copyBuildProgress is called as stores and files go in.
type copyBuildProgress func(copyProgress)

// copyAccounts: the vault's own keys (the owner and any added accounts).
func copyAccounts() map[string]bool {
	out := map[string]bool{}
	for k := range whitelist() {
		out[k] = true
	}
	return out
}

// copyOwnBlobRecords reads the blob index: sha256 -> uploader, own keys only
// (a record by anyone else can't be an own upload), and the record itself.
func copyOwnBlobRecords(ctx context.Context, accounts map[string]bool) (map[string]string, map[string]*nostr.Event, error) {
	uploader, records := map[string]string{}, map[string]*nostr.Event{}
	if blossomDB == nil {
		return uploader, records, nil
	}
	ch, err := blossomDB.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{Kinds: []int{24242}})
	if err != nil {
		return nil, nil, err
	}
	for ev := range ch {
		x := ev.Tags.GetFirst([]string{"x", ""})
		if x == nil || !isBlobHash((*x)[1]) || !accounts[ev.PubKey] {
			continue
		}
		if _, seen := uploader[(*x)[1]]; !seen {
			uploader[(*x)[1]] = ev.PubKey
			records[(*x)[1]] = ev
		}
	}
	return uploader, records, nil
}

// copyBlobFile: the stored file for sha256 (bare hash or hash.ext), never a
// partial .tmp write; "" when there is none.
func copyBlobFile(sha string) string {
	if st, err := os.Stat(config.BlossomPath + sha); err == nil && st.Mode().IsRegular() {
		return config.BlossomPath + sha
	}
	matches, _ := filepath.Glob(config.BlossomPath + sha + ".*")
	for _, m := range matches {
		if filepath.Ext(m) != ".tmp" {
			return m
		}
	}
	return ""
}

// copyDirBytes: what a directory tree holds on disk, for the space check.
func copyDirBytes(dir string) int64 {
	var n int64
	_ = filepath.WalkDir(dir, func(_ string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			if info, err := d.Info(); err == nil {
				n += info.Size()
			}
		}
		return nil
	})
	return n
}

// buildCopy writes notes.zip and media.zip into dir and returns the manifest
// (parts, counts, settings state). Each part is written as <name>.partial and
// renamed only when whole. A short disk is errCopyNoSpace.
func buildCopy(ctx context.Context, dir, id string, progress copyBuildProgress) (copyManifest, error) {
	m := copyManifest{V: 2, ID: id, State: "building", Owner: config.OwnerPubKey, CreatedAt: time.Now().Unix(), Counts: map[string]int{}}
	accountsRaw := marshalLocalCopyAccounts()
	keepRaw := marshalLocalCopyKeep()
	for _, a := range localCopyAccounts().Accounts {
		m.Accounts = append(m.Accounts, a.Npub)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return m, err
	}
	accounts := copyAccounts()
	uploaders, records, err := copyOwnBlobRecords(ctx, accounts)
	if err != nil {
		return m, err
	}
	media := map[string]string{} // sha -> file
	var mediaBytes int64
	for sha := range copyOwnMedia(uploaders, accounts) {
		if file := copyBlobFile(sha); file != "" {
			if st, err := os.Stat(file); err == nil {
				media[sha] = file
				mediaBytes += st.Size()
			}
		}
	}
	// The stores' size on disk bounds the jsonl (which compresses), plus the media.
	need := copyDirBytes("db") + mediaBytes + 100<<20
	if free, ok := freeBytes(dir); ok && free < uint64(need) {
		return m, errCopyNoSpace
	}

	stores := slices.DeleteFunc(slices.Sorted(maps.Keys(dbs)), filesStoreLeftOut)
	p := copyProgress{StoresTotal: len(stores), FilesTotal: len(media)}
	progress(p)

	// notes.zip: every store as the backup writes it; the blob index trimmed
	// to the files in media.zip; settings.json when it passes the check.
	notesPath := filepath.Join(dir, "notes.zip")
	settingsState, err := writeCopyNotes(ctx, notesPath, accountsRaw, keepRaw, stores, records, media, m.Counts, func() {
		p.StoresDone++
		progress(p)
	})
	if err != nil {
		return m, err
	}
	m.Settings = settingsState

	mediaPath := filepath.Join(dir, "media.zip")
	files, err := writeCopyMedia(ctx, mediaPath, media, func() {
		p.FilesDone++
		progress(p)
	})
	if err != nil {
		return m, err
	}
	m.Files = files

	for _, part := range []struct{ name, path string }{{"notes", notesPath}, {"media", mediaPath}} {
		cp, err := hashCopyPart(part.name, part.path)
		if err != nil {
			return m, err
		}
		m.Parts = append(m.Parts, cp)
	}
	m.ZipKey = copyZipKey(m.Parts)
	m.State = "ready"
	return m, nil
}

// copyCounter counts lines written (one event per line) for the manifest.
type copyCounter struct {
	w io.Writer
	n int
}

func (c *copyCounter) Write(b []byte) (int, error) {
	for _, x := range b {
		if x == '\n' {
			c.n++
		}
	}
	return c.w.Write(b)
}

func writeCopyNotes(ctx context.Context, path string, accounts, keep []byte, stores []string, records map[string]*nostr.Event, media map[string]string, counts map[string]int, storeDone func()) (settings string, err error) {
	partial := path + partialSuffix
	f, err := os.OpenFile(partial, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	defer func() {
		if err != nil {
			_ = f.Close()
			_ = os.Remove(partial)
		}
	}()
	zw := zip.NewWriter(f)
	// accounts.json first: B reads it before any store (§3.4).
	if err := writeZipAccounts(zw, accounts); err != nil {
		return "", err
	}
	// The keep list next: every account whose notes travel (copyKeepEntry).
	if len(keep) > 0 {
		if err := writeZipEntry(zw, copyKeepEntry, keep); err != nil {
			return "", err
		}
	}
	for _, name := range stores {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name + ".jsonl", Method: zip.Deflate, Modified: time.Now()})
		if err != nil {
			return "", err
		}
		c := &copyCounter{w: w}
		if name == "blossom" {
			// Only the records of files that travel: a record without its
			// file would tell B it has a photo it doesn't.
			for _, sha := range slices.Sorted(maps.Keys(media)) {
				if rec := records[sha]; rec != nil {
					if _, err := fmt.Fprintln(c, rec); err != nil {
						return "", err
					}
				}
			}
		} else if err := exportDB(ctx, dbs[name], c); err != nil {
			return "", fmt.Errorf("%s: %w", name, err)
		}
		counts[name] = c.n
		storeDone()
	}
	settings = "none"
	if raw, rerr := os.ReadFile(copySettingsFile); rerr == nil {
		if why := copySettingsRefusal(raw, time.Now()); why != "" {
			slog.Warn("copy: settings not included", "reason", why)
			settings = "refused"
		} else {
			w, err := zw.CreateHeader(&zip.FileHeader{Name: "settings.json", Method: zip.Deflate, Modified: time.Now()})
			if err != nil {
				return "", err
			}
			if _, err := w.Write(raw); err != nil {
				return "", err
			}
			settings = "included"
		}
	}
	if err := zw.Close(); err != nil {
		return "", err
	}
	if err := f.Sync(); err != nil {
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	return settings, os.Rename(partial, path)
}

// writeCopyMedia stores each file as media/<sha256>, uncompressed, checking
// its bytes against its name on the way: a damaged file is left out rather
// than sent.
func writeCopyMedia(ctx context.Context, path string, media map[string]string, fileDone func()) (files copyFiles, err error) {
	partial := path + partialSuffix
	f, err := os.OpenFile(partial, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return files, err
	}
	defer func() {
		if err != nil {
			_ = f.Close()
			_ = os.Remove(partial)
		}
	}()
	zw := zip.NewWriter(f)
	for _, sha := range slices.Sorted(maps.Keys(media)) {
		if ctx.Err() != nil {
			return files, ctx.Err()
		}
		// Hashed first, then copied, both streamed: a video can be larger
		// than a phone's memory, and a zip entry can't be taken back.
		if got, _, herr := copyFileHash(media[sha]); herr != nil || got != sha {
			slog.Warn("copy: file unreadable or not matching its hash, left out", "sha256", sha)
			continue
		}
		w, err := zw.CreateHeader(&zip.FileHeader{Name: "media/" + sha, Method: zip.Store, Modified: time.Now()})
		if err != nil {
			return files, err
		}
		src, err := os.Open(media[sha])
		if err != nil {
			return files, err
		}
		n, err := io.Copy(w, src)
		src.Close()
		if err != nil {
			return files, err
		}
		files.Count++
		files.Bytes += n
		fileDone()
	}
	if err := zw.Close(); err != nil {
		return files, err
	}
	if err := f.Sync(); err != nil {
		return files, err
	}
	if err := f.Close(); err != nil {
		return files, err
	}
	return files, os.Rename(partial, path)
}

// hashCopyPart: a part's size, whole sha256 and 4 MiB chunk hashes.
func hashCopyPart(name, path string) (copyPart, error) {
	p := copyPart{Name: name, Chunk: copyChunkSize, Chunks: []string{}}
	f, err := os.Open(path)
	if err != nil {
		return p, err
	}
	defer f.Close()
	whole := sha256.New()
	buf := make([]byte, copyChunkSize)
	for {
		n, err := io.ReadFull(f, buf)
		if n > 0 {
			sum := sha256.Sum256(buf[:n])
			p.Chunks = append(p.Chunks, hex.EncodeToString(sum[:]))
			whole.Write(buf[:n])
			p.Size += int64(n)
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return p, err
		}
	}
	p.SHA256 = hex.EncodeToString(whole.Sum(nil))
	return p, nil
}

// copyFileHash streams a file's sha256 and size.
func copyFileHash(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}
