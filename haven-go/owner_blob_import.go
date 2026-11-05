//go:build !(js && wasm)

package main

import (
	"context"
	"errors"
	"os"
	"strconv"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// importOwnerBlob stores the file at path in this vault's Blossom store as
// the owner's, the way a signed upload by the owner would: the file under its
// hash, and its blob record in Keep's shape (x, type, size), so /list and
// GET serve it like any upload.
//
// It is the app's own way in for a vault with no account key (npub only),
// which cannot sign the kind 24242 the HTTP upload needs. It is not an HTTP
// route: only the app this library runs inside can call it (ImportOwnerBlobC),
// so the upload rule for everyone else (init.go RejectUpload: signed by a
// whitelisted key) is unchanged. The file must hash to sha256, and a type a
// browser would run (activeBlobTypes) is refused, as on restore.
func importOwnerBlob(ctx context.Context, path, sha256, mimeType string) error {
	if blossomDB == nil || config.OwnerPubKey == "" {
		return errors.New("vault media store is not open")
	}
	if !isBlobHash(sha256) {
		return errors.New("not a sha256")
	}
	if !isRestorableBlobType(mimeType) {
		return errors.New("media type not allowed")
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return errors.New("not a file")
	}
	ok, err := storeCopyBlob(sha256, f)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("file does not match its sha256")
	}
	size := st.Size()
	if stored := copyBlobFile(sha256); stored != "" {
		if info, err := os.Stat(stored); err == nil {
			size = info.Size()
		}
	}
	rec := &nostr.Event{PubKey: config.OwnerPubKey, Kind: 24242, CreatedAt: nostr.Now(),
		Tags: nostr.Tags{{"x", sha256}, {"type", mimeType}, {"size", strconv.FormatInt(size, 10)}}}
	rec.ID = rec.GetID()
	switch importBlobRecord(ctx, blossomDB, rec, time.Now()) {
	case restoreStored, restoreDup:
		return nil
	default:
		return errors.New("blob record not stored")
	}
}
