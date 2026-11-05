//go:build !(js && wasm)

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

var ownerBlobImportMu sync.Mutex

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
//
// One at a time: the app fetches several files at once, and the same blob
// linked from two servers would otherwise be written to the same <sha>.tmp
// by two calls together.
func importOwnerBlob(ctx context.Context, path, sha256, mimeType string) error {
	ownerBlobImportMu.Lock()
	defer ownerBlobImportMu.Unlock()
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
	if err := storeOwnerBlobFile(sha256, f); err != nil {
		return err
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

// storeOwnerBlobFile puts r at <BlossomPath><sha> unless a file for that hash
// is already there. It writes through a temp file of its own
// (<sha>.<random>.tmp), never the shared <sha>.tmp the copy and upload paths
// use, so an overlapping write of the same blob can't rename a half-written
// file into place. Renamed only once the bytes hash to sha.
func storeOwnerBlobFile(sha string, r io.Reader) error {
	if copyBlobFile(sha) != "" {
		return nil
	}
	tmp, err := os.CreateTemp(config.BlossomPath, sha+".*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), r); err != nil {
		tmp.Close()
		_ = os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(name)
		return err
	}
	if hex.EncodeToString(h.Sum(nil)) != sha {
		_ = os.Remove(name)
		return errors.New("file does not match its sha256")
	}
	if err := os.Chmod(name, 0o600); err != nil {
		_ = os.Remove(name)
		return err
	}
	if err := os.Rename(name, config.BlossomPath+sha); err != nil {
		_ = os.Remove(name)
		return err
	}
	return nil
}
