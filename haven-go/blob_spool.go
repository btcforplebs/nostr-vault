package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"hash"
	"io"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// maxBlobBytes caps one blob received over any port: an upload, a mirror,
// the mesh door. The apps show blossom.TooLargeReason with the 413.
const maxBlobBytes = 256 << 20

// fileSpool streams a received blob into its own temp file in the blob
// folder (upload.<random>.tmp), hashing as it goes, so a 256 MB video is
// never held in memory. Commit renames it to <sha256> once khatru's checks
// passed; until then it ends in .tmp, so it is never served
// (isPartialBlobPath) and a cut-off one is swept (sweepStaleBlobTemps).
type fileSpool struct {
	fsys afero.Fs
	f    afero.File
	h    hash.Hash
	done bool
}

func newFileSpool(fsys afero.Fs) (*fileSpool, error) {
	f, err := afero.TempFile(fsys, config.BlossomPath, "upload.*.tmp")
	if err != nil {
		return nil, err
	}
	return &fileSpool{fsys: fsys, f: f, h: sha256.New()}, nil
}

func (s *fileSpool) Write(p []byte) (int, error) {
	n, err := s.f.Write(p)
	s.h.Write(p[:n])
	return n, err
}

func (s *fileSpool) Commit(_ context.Context, sha, _ string) error {
	name := s.f.Name()
	if err := s.f.Close(); err != nil {
		s.Discard()
		return err
	}
	if hex.EncodeToString(s.h.Sum(nil)) != sha {
		s.Discard()
		return errors.New("blob does not match its sha256")
	}
	if err := s.fsys.Rename(name, config.BlossomPath+sha); err != nil {
		s.Discard()
		return err
	}
	s.done = true
	return nil
}

func (s *fileSpool) Discard() {
	if s.done {
		return
	}
	s.done = true
	_ = s.f.Close()
	_ = s.fsys.Remove(s.f.Name())
}

// blobCovered: a token that names its blobs (x tags) covers only those, on
// every port. Without it a public Blossom server holding one of the owner's
// upload tokens could park any 256 MB file here until the token expires.
// Over the mesh door a token must name the blob: a public mirror holds one
// for its hour, and it cannot put anything else here.
func blobCovered(ctx context.Context, auth *nostr.Event, sha string, _ int) (bool, string, int) {
	if auth.Tags.FindWithValue("x", sha) != nil {
		return false, "", 0
	}
	if ctx.Value(meshPeerKey{}) != nil || auth.Tags.Find("x") != nil {
		return true, "authorization does not cover this blob", 403
	}
	return false, "", 0
}

// wireBlobReceive: every blob in under one cap; natively it streams to disk
// (blobSpool). The web vault keeps its blobs in memory anyway, so there the
// memory spool hands the bytes to StoreBlob in one write.
func wireBlobReceive(bs *blossom.BlossomServer) {
	bs.MaxUploadSize = maxBlobBytes
	bs.SpoolBlob = blobSpool
	bs.StoreBlob = append(bs.StoreBlob, func(ctx context.Context, sha256 string, ext string, body io.Reader) error {
		// writeBlobFile: a temp file of its own, renamed into place only when
		// the bytes hash to sha256.
		ok, err := writeBlobFile(fs, sha256, body)
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("blob does not match its sha256")
		}
		return nil
	})
	bs.RejectBlob = append(bs.RejectBlob, blobCovered)
}
