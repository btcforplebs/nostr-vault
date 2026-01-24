//go:build darwin

package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
)

func loadBlob(ctx context.Context, sha256 string, ext string) (io.ReadSeeker, error) {
	slog.Debug("loading blob (macOS Sandbox fix)", "sha256", sha256, "ext", ext)
	f, err := fs.Open(config.BlossomPath + sha256)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// In the macOS Sandbox, streaming files via http.ServeContent (sendfile)
	// often fails or cuts off at 512 bytes. Reading the entire file into
	// memory first bypasses the problematic system calls.
	data, err := io.ReadAll(f)
	if err != nil {
		slog.Error("failed to read file to memory in sandbox", "error", err)
		return nil, err
	}

	return bytes.NewReader(data), nil
}
