package blossom

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"

	"github.com/nbd-wtf/go-nostr"
)

// Spool takes a blob's bytes as they arrive, so a receive never holds the
// whole blob in memory. Commit files it under its sha256 once every check
// passed; Discard drops it (a no-op after Commit).
type Spool interface {
	io.Writer
	Commit(ctx context.Context, sha256, ext string) error
	Discard()
}

// memorySpool is the spool when SpoolBlob is unset: the bytes in memory,
// handed to the StoreBlob hooks on Commit.
type memorySpool struct {
	bs  *BlossomServer
	buf bytes.Buffer
}

func (m *memorySpool) Write(p []byte) (int, error) { return m.buf.Write(p) }
func (m *memorySpool) Discard()                    { m.buf = bytes.Buffer{} }
func (m *memorySpool) Commit(ctx context.Context, sha256, ext string) error {
	for _, sb := range m.bs.StoreBlob {
		if err := sb(ctx, sha256, ext, bytes.NewReader(m.buf.Bytes())); err != nil {
			return err
		}
	}
	return nil
}

// newSpool: SpoolBlob's, or a memory spool sized for hint (the declared
// length) so it doesn't regrow on the way.
func (bs BlossomServer) newSpool(ctx context.Context, hint int64) (Spool, error) {
	if bs.SpoolBlob != nil {
		return bs.SpoolBlob(ctx)
	}
	m := &memorySpool{bs: &bs}
	if hint > 0 && !bs.tooLarge(hint) {
		m.buf.Grow(int(hint))
	}
	return m, nil
}

// TooLargeReason is the X-Reason of a 413: the apps show it to the person.
func TooLargeReason(max int64) string {
	return fmt.Sprintf("this vault takes files up to %d MB", max>>20)
}

// tooLarge: n bytes would pass MaxUploadSize.
func (bs BlossomServer) tooLarge(n int64) bool {
	return bs.MaxUploadSize > 0 && n > bs.MaxUploadSize
}

// declaredLength is the upload's Content-Length, or -1.
func declaredLength(r *http.Request) int64 {
	if r.ContentLength > 0 {
		return r.ContentLength
	}
	if n, err := strconv.ParseInt(r.Header.Get("Content-Length"), 10, 64); err == nil && n > 0 {
		return n
	}
	return -1
}

// authorizeUpload runs the RejectUpload hooks before a single body byte is
// read: who signed is known from the header alone. size is what the request
// declares (0 when it can't), ext what its headers say.
func (bs BlossomServer) authorizeUpload(ctx context.Context, auth *nostr.Event, size int, ext string) (bool, string, int) {
	for _, ru := range bs.RejectUpload {
		if reject, reason, code := ru(ctx, auth, size, ext); reject {
			return true, reason, code
		}
	}
	return false, "", 0
}

var errTooLarge = errors.New("too large")

// spoolBody streams src into a new spool through sha256, refusing more than
// MaxUploadSize. head is bytes already read from src (for the file type),
// hint the length the sender declared (0 or -1 when unknown).
func (bs BlossomServer) spoolBody(ctx context.Context, head []byte, src io.Reader, hint int64) (Spool, string, int64, error) {
	sp, err := bs.newSpool(ctx, hint)
	if err != nil {
		return nil, "", 0, err
	}
	if bs.MaxUploadSize > 0 {
		src = io.LimitReader(src, bs.MaxUploadSize-int64(len(head))+1)
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(sp, h), io.MultiReader(bytes.NewReader(head), src))
	if err == nil && bs.tooLarge(n) {
		err = errTooLarge
	}
	if err != nil {
		sp.Discard()
		return nil, "", 0, err
	}
	return sp, hex.EncodeToString(h.Sum(nil)), n, nil
}

// rejectBlob runs the RejectBlob hooks once the blob's hash is known.
func (bs BlossomServer) rejectBlob(ctx context.Context, auth *nostr.Event, sha string, size int64) (bool, string, int) {
	for _, rb := range bs.RejectBlob {
		if reject, reason, code := rb(ctx, auth, sha, int(size)); reject {
			return true, reason, code
		}
	}
	return false, "", 0
}
