package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"

	"github.com/spf13/afero"
)

// writeBlobFile puts r at <BlossomPath><sha> on fsys through a temp file of
// its own (<sha>.<random>.tmp), renamed into place only when the bytes hash
// to sha. False (and nothing written) when they don't.
//
// Every blob writer used one shared <sha>.tmp (O_TRUNC): two writes of the
// same blob at once (an upload, a mesh copy catch-up, a copy restore, Import
// media) could rename the other's half-written file into place, and the
// truncated <sha> then counted as stored and was never fetched again. With a
// temp file per call, whichever finishes renames a whole file; the rename is
// atomic, so the other only replaces it with the same bytes.
//
// The name still ends in .tmp, so it is never served (isPartialBlobPath), is
// swept when stale (sweepStaleBlobTemps), and stays in memory on the web
// vault (blobFs.stored).
func writeBlobFile(fsys afero.Fs, sha string, r io.Reader) (bool, error) {
	tmp, err := afero.TempFile(fsys, config.BlossomPath, sha+".*.tmp")
	if err != nil {
		return false, err
	}
	name := tmp.Name()
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), r); err != nil {
		tmp.Close()
		_ = fsys.Remove(name)
		return false, err
	}
	if err := tmp.Close(); err != nil {
		_ = fsys.Remove(name)
		return false, err
	}
	if hex.EncodeToString(h.Sum(nil)) != sha {
		_ = fsys.Remove(name)
		return false, nil
	}
	if err := fsys.Rename(name, config.BlossomPath+sha); err != nil {
		_ = fsys.Remove(name)
		return false, err
	}
	return true, nil
}
