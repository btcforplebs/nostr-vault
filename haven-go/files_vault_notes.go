package main

// The vault writes the file note itself (Logen's go, 2026-11-13): a new
// upload or mirror of the owner's media gets a kind 1063 on /files, so a file
// from an app built before the live notes (#1993), Android, the browser vault
// or any other Blossom client shows up live on every open Media tab too.
//
//   - Signed with the vault's own /files key (files_backfill.go), never the
//     account key: the engine holds no account key or app mesh secret here.
//   - No double notes: the apps send their own note (their device mesh key)
//     right after an upload, so the vault waits filesUploadGrace and writes
//     only if no trusted note names that hash by then (dedupe by hash).
//   - The owner's media only (filed under the owner, as /files takes p =
//     owner); nothing for a file deleted in the meantime, or one whose save
//     failed (the record is filed before the file is saved, Tron #2000).

import (
	"context"
	"log/slog"
	"strconv"
	"time"

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// filesUploadGrace: how long the app has to send its own note first.
const filesUploadGrace = 20 * time.Second

// filesAfterUpload runs f after d (tests run it by hand).
var filesAfterUpload = func(d time.Duration, f func()) {
	time.AfterFunc(d, func() { runsafe.Run("files-vault-note", f) })
}

// filesBlobKept: a blob was filed under indexKey (meshOwnerIndex.Keep).
func filesBlobKept(blob blossom.BlobDescriptor, indexKey string) {
	if filesDB == nil || config.OwnerPubKey == "" || indexKey != config.OwnerPubKey || !isBlobHash(blob.SHA256) {
		return
	}
	filesAfterUpload(filesUploadGrace, func() { writeVaultFileNote(context.Background(), blob) })
}

// writeVaultFileNote: one note (the vault's key) for blob, unless a trusted
// note already names it or the owner's record is gone.
func writeVaultFileNote(ctx context.Context, blob blossom.BlobDescriptor) {
	if filesDB == nil || blossomDB == nil || filesRelay == nil || config.OwnerPubKey == "" {
		return
	}
	if filesHasTrustedNote(ctx, blob.SHA256) || !ownerHasBlobRecord(ctx, blob.SHA256) || !blobOnDisk(blob.SHA256) {
		return
	}
	sk := filesVaultSecret()
	if sk == "" {
		return
	}
	mime := blob.Type
	if mime == "" {
		mime = "application/octet-stream"
	}
	note := nostr.Event{Kind: kindFileMetadata, CreatedAt: nostr.Timestamp(filesNow().Unix()), Tags: nostr.Tags{
		{"x", blob.SHA256}, {"m", mime}, {"size", strconv.Itoa(max(blob.Size, 0))}, {"p", config.OwnerPubKey}, {"client", "nostr-vault"},
	}}
	if note.Sign(sk) != nil {
		return
	}
	if err := filesDB.SaveEvent(ctx, &note); err != nil {
		slog.Warn("files: saving the vault's note for an upload", "error", err)
		return
	}
	filesRelay.BroadcastEvent(&note)
}

// filesHasTrustedNote: some key /files still trusts has a note for x.
func filesHasTrustedNote(ctx context.Context, x string) bool {
	ch, err := filesDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{kindFileMetadata}, Tags: nostr.TagMap{"x": []string{x}}})
	if err != nil {
		return true // can't tell: no note rather than a double
	}
	found := false
	for ev := range ch { // drained to the end, so the store's query finishes
		if filesWriter(ev.PubKey) {
			found = true
		}
	}
	return found
}

// ownerHasBlobRecord: the owner's Blossom record for x is still here.
func ownerHasBlobRecord(ctx context.Context, x string) bool {
	ch, err := blossomDB.QueryEvents(ctx, nostr.Filter{Kinds: []int{24242}, Authors: []string{config.OwnerPubKey}, Tags: nostr.TagMap{"x": []string{x}}, Limit: 1})
	if err != nil {
		return false
	}
	found := false
	for range ch {
		found = true
	}
	return found
}

// blobOnDisk: the stored file for x is here (bare hash or hash.ext, never a
// partial .tmp write), through the platform fs as loadBlob reads it.
func blobOnDisk(x string) bool {
	if st, err := fs.Stat(config.BlossomPath + x); err == nil && st.Mode().IsRegular() {
		return true
	}
	return len(blobFilesWithExt(x)) > 0
}
