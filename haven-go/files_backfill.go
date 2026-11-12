package main

// The vault's own key for /files, and the one-time backfill of its blobs.
//
// The engine does not hold this vault's mesh secret (the apps keep it), so
// the notes the vault itself writes (the backfill, and the kind 5 when it
// deletes a blob, files_relay.go) are signed with a key of its own, kept in
// files_key next to copy_tokens.json. It signs nothing but /files notes and
// never leaves this machine. Readers trust /files as a whole (the relay is
// the anchor), so a new key (file lost) only means the backfill runs again;
// notes under the old key stop being served.

import (
	"context"
	"encoding/hex"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

var (
	filesKeyFile      = "files_key"
	filesBackfillFile = "files_backfill_done"
)

var filesKey struct {
	mu     sync.Mutex
	sk, pk string
}

// filesVaultSecret loads (or makes and saves) the vault's /files key.
func filesVaultSecret() string {
	filesKey.mu.Lock()
	defer filesKey.mu.Unlock()
	if filesKey.sk != "" {
		return filesKey.sk
	}
	if raw, err := os.ReadFile(filesKeyFile); err == nil {
		sk := strings.TrimSpace(string(raw))
		if b, err := hex.DecodeString(sk); err == nil && len(b) == 32 {
			if pk, err := nostr.GetPublicKey(sk); err == nil {
				filesKey.sk, filesKey.pk = sk, pk
				return sk
			}
		}
	}
	sk := nostr.GeneratePrivateKey()
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		return ""
	}
	tmp := filesKeyFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(sk), 0o600); err != nil || os.Rename(tmp, filesKeyFile) != nil {
		// Held for this run only: notes signed now are hidden after a restart,
		// and the backfill runs again then.
		slog.Warn("files: could not save the vault's media-notes key", "error", err)
	}
	filesKey.sk, filesKey.pk = sk, pk
	return sk
}

// filesVaultPubKey: the vault's /files key, "" if it has none.
func filesVaultPubKey() string {
	filesKey.mu.Lock()
	pk := filesKey.pk
	filesKey.mu.Unlock()
	if pk != "" {
		return pk
	}
	filesVaultSecret()
	filesKey.mu.Lock()
	defer filesKey.mu.Unlock()
	return filesKey.pk
}

// backfillFileNotes: once per vault key, one kind 1063 (the vault's key) per
// blob the owner's records name, with no server URLs (the file is here). A
// note already there for that hash is skipped, so a cut-off run picks up
// where it stopped.
func backfillFileNotes(ctx context.Context) {
	if filesDB == nil || blossomDB == nil || config.OwnerPubKey == "" {
		return
	}
	sk := filesVaultSecret()
	pk := filesVaultPubKey()
	if sk == "" {
		return
	}
	if raw, err := os.ReadFile(filesBackfillFile); err == nil && strings.TrimSpace(string(raw)) == pk {
		return
	}
	ch, err := blossomDB.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{Kinds: []int{24242}, Authors: []string{config.OwnerPubKey}})
	if err != nil {
		return
	}
	var records []*nostr.Event
	for ev := range ch {
		records = append(records, ev)
	}
	added := 0
	for _, rec := range records {
		x := rec.Tags.GetFirst([]string{"x", ""})
		if x == nil || !isBlobHash((*x)[1]) || filesHasNote(ctx, pk, (*x)[1]) {
			continue
		}
		mime := "application/octet-stream"
		if t := rec.Tags.GetFirst([]string{"type", ""}); t != nil && (*t)[1] != "" {
			mime = (*t)[1]
		}
		size := "0"
		if s := rec.Tags.GetFirst([]string{"size", ""}); s != nil {
			if _, err := strconv.ParseInt((*s)[1], 10, 64); err == nil {
				size = (*s)[1]
			}
		}
		note := nostr.Event{Kind: kindFileMetadata, CreatedAt: nostr.Timestamp(filesNow().Unix()), Tags: nostr.Tags{
			{"x", (*x)[1]}, {"m", mime}, {"size", size}, {"p", config.OwnerPubKey}, {"client", "nostr-vault"},
		}}
		if note.Sign(sk) != nil {
			continue
		}
		if err := filesDB.SaveEvent(ctx, &note); err != nil {
			slog.Warn("files: backfill", "error", err)
			return // try again next start
		}
		added++
	}
	tmp := filesBackfillFile + ".tmp"
	if os.WriteFile(tmp, []byte(pk), 0o600) == nil {
		_ = os.Rename(tmp, filesBackfillFile)
	}
	if added > 0 {
		slog.Info("files: backfilled media notes", "notes", added)
	}
}
