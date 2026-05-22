//go:build darwin

package main

import (
	"context"
	"io"
	"log/slog"
)

func loadBlob(_ context.Context, sha256 string, ext string) (io.ReadSeeker, error) {
	slog.Debug("loading blob", "sha256", sha256, "ext", ext)
	f, err := openBlobFile(sha256, ext)
	if err != nil {
		return nil, err
	}

	// macOS Sandbox workaround: http.ServeContent uses sendfile which often
	// fails/truncates at 512 bytes inside the App Sandbox.
	// Wrapping in safeReader implements io.WriterTo so http.ServeContent
	// uses userspace copying instead of sendfile.
	// See: https://github.com/golang/go/issues/70000
	return safeReader{f}, nil
}

// safeReader wraps an io.ReadSeeker to bypass sendfile by implementing io.WriterTo.
type safeReader struct {
	io.ReadSeeker
}

// WriteTo implements io.WriterTo with a 256KB buffer to reduce syscalls.
func (s safeReader) WriteTo(dst io.Writer) (int64, error) {
	buf := make([]byte, 256*1024)
	return io.CopyBuffer(dst, s.ReadSeeker, buf)
}
