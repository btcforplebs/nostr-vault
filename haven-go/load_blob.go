package main

import (
	"errors"
	iofs "io/fs"
	"log/slog"
	"strings"
	"time"

	"github.com/spf13/afero"
)

// partialBlobSuffixes mark a blob file that isn't the blob: StoreBlob's
// write-then-rename temp (init.go), a file the viewer set aside as broken,
// and the download and restore temps the apps use. Serving or counting one
// would hand out cut bytes under the real hash, marked immutable.
var partialBlobSuffixes = []string{".tmp", ".corrupt", ".part", ".restoring", ".download"}

func isPartialBlobPath(path string) bool {
	for _, suffix := range partialBlobSuffixes {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}

func openBlobFile(sha256 string, ext string) (afero.File, error) {
	basePath := config.BlossomPath + sha256

	file, err := fs.Open(basePath)
	if err == nil {
		return file, nil
	}

	if ext != "" {
		normalizedExt := ext
		if !strings.HasPrefix(normalizedExt, ".") {
			normalizedExt = "." + normalizedExt
		}
		if path := basePath + normalizedExt; !isPartialBlobPath(path) {
			if fileWithExt, extErr := fs.Open(path); extErr == nil {
				return fileWithExt, nil
			}
		}
	}

	for _, match := range blobFilesWithExt(sha256) {
		if fileWithAnyExt, matchErr := fs.Open(match); matchErr == nil {
			return fileWithAnyExt, nil
		}
	}

	return nil, err
}

// blobFilesWithExt: the stored `<sha256>.<ext>` copies of a blob, never a
// partial file.
func blobFilesWithExt(sha256 string) []string {
	matches, err := afero.Glob(fs, config.BlossomPath+sha256+".*")
	if err != nil {
		return nil
	}
	out := matches[:0]
	for _, m := range matches {
		if !isPartialBlobPath(m) {
			out = append(out, m)
		}
	}
	return out
}

// deleteBlobFiles removes a blob under every name it is served by: the bare
// hash and each `<sha256>.<ext>` copy. Removing only the bare file left the
// others to be served after a delete.
func deleteBlobFiles(sha256 string) error {
	removed := 0
	baseErr := fs.Remove(config.BlossomPath + sha256)
	if baseErr == nil {
		removed++
	}
	for _, m := range blobFilesWithExt(sha256) {
		if err := fs.Remove(m); err == nil {
			removed++
		} else if !errors.Is(err, iofs.ErrNotExist) {
			return err
		}
	}
	if removed > 0 {
		return nil
	}
	return baseErr
}

// staleBlobTempAge: a StoreBlob temp older than this is from a write that
// was cut off (a kill, a crash), not one in flight.
const staleBlobTempAge = time.Hour

// sweepStaleBlobTemps removes the temps cut-off writes left in the blob
// folder. Run once at start, before the blob server takes uploads.
func sweepStaleBlobTemps(now time.Time) {
	matches, err := afero.Glob(fs, config.BlossomPath+"*.tmp")
	if err != nil {
		return
	}
	for _, m := range matches {
		info, err := fs.Stat(m)
		if err != nil || info.IsDir() || now.Sub(info.ModTime()) < staleBlobTempAge {
			continue
		}
		if err := fs.Remove(m); err == nil {
			slog.Info("🧹 removed a cut-off blob write", "file", m)
		}
	}
}
