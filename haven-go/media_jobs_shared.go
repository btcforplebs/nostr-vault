//go:build !(js && wasm)

package main

// What Auto-Mirror (auto_mirror.go) and Copy to servers (media_copy_job.go)
// share: the accounts, their servers, the guarded client, storing a file as
// an account without a key, and the files the box reads and writes.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// ── Storing as an account (keyless) ─────────────────────────────────────

// storeAccountBlob stores the file at file as pubkey's upload, the way
// importOwnerBlob does for the owner: the file under its hash and a blob
// record (x, type, size). pubkey must be one of the vault's own signing
// accounts; the caller checks that.
func storeAccountBlob(ctx context.Context, pubkey, file, sha, mimeType string) error {
	ownerBlobImportMu.Lock()
	defer ownerBlobImportMu.Unlock()
	if blossomDB == nil {
		return errors.New("vault media store is not open")
	}
	if !isBlobHash(sha) || !isLowerHex64(pubkey) {
		return errors.New("bad hash or account")
	}
	if !isRestorableBlobType(mimeType) {
		return errors.New("media type not allowed")
	}
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return errors.New("not a file")
	}
	if err := storeOwnerBlobFile(sha, f); err != nil {
		return err
	}
	_, err = addAccountBlobRecord(ctx, pubkey, sha, mimeType, st.Size())
	return err
}

// claimAccountBlob: pubkey's record for a file another account already
// stored here, so it is pubkey's file too (Tron #2386). The bytes are not
// touched. added: false when pubkey already had the record.
func claimAccountBlob(ctx context.Context, pubkey, sha string) (bool, error) {
	ownerBlobImportMu.Lock()
	defer ownerBlobImportMu.Unlock()
	if blossomDB == nil {
		return false, errors.New("vault media store is not open")
	}
	if !isBlobHash(sha) || !isLowerHex64(pubkey) {
		return false, errors.New("bad hash or account")
	}
	file := copyBlobFile(sha)
	if file == "" {
		return false, errors.New("not stored here")
	}
	st, err := os.Stat(file)
	if err != nil || !st.Mode().IsRegular() {
		return false, errors.New("not a file")
	}
	mimeType := storedBlobType(sha)
	if !isRestorableBlobType(mimeType) {
		return false, errors.New("media type not allowed")
	}
	return addAccountBlobRecord(ctx, pubkey, sha, mimeType, st.Size())
}

// addAccountBlobRecord: the 24242 record that makes sha pubkey's file.
// Caller holds ownerBlobImportMu.
func addAccountBlobRecord(ctx context.Context, pubkey, sha, mimeType string, size int64) (bool, error) {
	rec := &nostr.Event{PubKey: pubkey, Kind: 24242, CreatedAt: nostr.Now(),
		Tags: nostr.Tags{{"x", sha}, {"type", mimeType}, {"size", strconv.FormatInt(size, 10)}}}
	rec.ID = rec.GetID()
	switch importBlobRecord(ctx, blossomDB, rec, time.Now()) {
	case restoreStored:
		return true, nil
	case restoreDup:
		return false, nil
	default:
		return false, errors.New("blob record not stored")
	}
}

// ── Wiring to the live engine ───────────────────────────────────────────

// mediaJobsClient fetches from outside servers: never a private address,
// whatever name led there (forwardDialControl), up to 5 redirects.
var mediaJobsClient = &http.Client{
	Timeout: 10 * time.Minute,
	Transport: &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second, Control: forwardDialControl}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if req.URL.Scheme != "https" && req.URL.Scheme != "http" {
			return errors.New("redirect to a non-http link")
		}
		return nil
	},
}

// ownSigningAccounts: the owner and each signed-in account, hex
// (localCopyAccounts: never a watch-only one).
func ownSigningAccounts() []string {
	var out []string
	for _, a := range localCopyAccounts().Accounts {
		if h, ok := npubHex(a.Npub); ok {
			out = append(out, h)
		}
	}
	return out
}

// accountServers: the servers in pubkey's newest 10063 on this relay,
// outside https servers only, no trailing slash.
func accountServers(ctx context.Context, pubkey string) []string {
	if outboxDB == nil {
		return nil
	}
	qctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ch, err := outboxDB.QueryEvents(qctx, nostr.Filter{Kinds: []int{10063}, Authors: []string{pubkey}, Limit: 1})
	if err != nil {
		return nil
	}
	var newest *nostr.Event
	for ev := range ch {
		if newest == nil || ev.CreatedAt > newest.CreatedAt {
			newest = ev
		}
	}
	if newest == nil {
		return nil
	}
	return serversOf(newest.Tags)
}

// serversOf: the 10063 "server" tags that are outside https servers, each once.
func serversOf(tags nostr.Tags) []string {
	var out []string
	for _, tag := range tags {
		if len(tag) < 2 || tag[0] != "server" {
			continue
		}
		s := strings.TrimRight(strings.TrimSpace(tag[1]), "/")
		u, err := url.Parse(s)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || forwardHostRefused(u.Hostname()) {
			continue
		}
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}

func blobStoredHere(sha string) bool { return copyBlobFile(sha) != "" }

func readJSONFile(file string, v any) bool {
	raw, err := os.ReadFile(file)
	return err == nil && json.Unmarshal(raw, v) == nil
}

func writeJSONFile(file string, v any) {
	raw, err := json.Marshal(v)
	if err == nil {
		err = writeFileAtomic(file, raw)
	}
	if err != nil {
		slog.Warn("could not save", "file", file, "err", err)
	}
}

// shaWriter hashes what is written to it.
type shaWriter struct{ h hash.Hash }

func newSHA256() *shaWriter                      { return &shaWriter{h: sha256.New()} }
func (s *shaWriter) Write(p []byte) (int, error) { return s.h.Write(p) }
func (s *shaWriter) hex() string                 { return hex.EncodeToString(s.h.Sum(nil)) }
