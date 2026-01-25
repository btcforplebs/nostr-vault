//go:build darwin

package main

import (
	"context"
	"io"
	"os"
)

func loadBlob(ctx context.Context, sha256 string, ext string) (io.ReadSeeker, error) {
	f, err := os.Open(config.BlossomPath + sha256)
	if err != nil {
		return nil, err
	}

	// macOS Sandbox workaround: http.ServeContent (sendfile) often fails/truncates at 512 bytes.
	// We wrap *os.File in safeFile to force userspace copying with a larger 256KB buffer for performance.
	// See: https://github.com/golang/go/issues/70000
	return safeFile{f}, nil
}

// safeFile wraps *os.File to bypass sendfile, ensuring reliable streaming in the macOS Sandbox.
type safeFile struct {
	*os.File
}

// WriteTo implements io.WriterTo with a 256KB buffer to reduce syscalls.
func (s safeFile) WriteTo(dst io.Writer) (int64, error) {
	buf := make([]byte, 256*1024)
	return io.CopyBuffer(dst, s.File, buf)
}
