//go:build !darwin

package main

import (
	"context"
	"io"
	"log/slog"
)

func loadBlob(_ context.Context, sha256 string, ext string) (io.ReadSeeker, error) {
	slog.Debug("loading blob", "sha256", sha256, "ext", ext)
	return fs.Open(config.BlossomPath + sha256)
}
