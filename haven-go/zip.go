package main

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ZipDirectory creates a zip archive of the source directory. The archive's
// index is written on Close, so both closes are checked: a full disk there
// leaves a zip that won't open, and that must not count as a backup.
func ZipDirectory(source, target string) error {
	zipFile, err := os.Create(target)
	if err != nil {
		return err
	}
	if err := zipDirectoryTo(source, zipFile); err != nil {
		return fmt.Errorf("zip %s: %w", target, err)
	}
	return nil
}

// zipDirectoryTo writes source's zip to out and closes out.
func zipDirectoryTo(source string, out io.WriteCloser) error {
	archive := zip.NewWriter(out)
	walkErr := zipWalk(archive, filepath.Clean(source))
	closeErr := archive.Close()
	fileErr := out.Close()
	return errors.Join(walkErr, closeErr, fileErr)
}

func zipWalk(archive *zip.Writer, source string) error {
	return filepath.Walk(source, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Get relative path for the zip header
		relPath, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}

		// Skip the base directory itself
		if relPath == "." {
			return nil
		}

		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}

		header.Name = relPath
		if info.IsDir() {
			header.Name += "/"
		} else {
			header.Method = zip.Deflate
		}

		writer, err := archive.CreateHeader(header)
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()

		_, err = io.Copy(writer, file)
		return err
	})
}

// unzipKeepFree is left free on the device by an unzip: a media restore
// that fills the disk would take the vault (and the phone) down with it.
const unzipKeepFree = 1 << 30 // 1 GiB

// unzipMaxEntries caps the files one archive may unpack.
const unzipMaxEntries = 1_000_000

// unzipFallbackCap is the byte cap when free space can't be measured.
const unzipFallbackCap = 64 << 30 // 64 GiB

// unzipFreeBytes measures free space; a test stands in for a full disk.
var unzipFreeBytes = freeBytes

var errUnzipTooBig = errors.New("archive is bigger than the free space on this device")

// UnzipDirectory extracts a zip archive to the destination directory. It
// stops once the bytes written (counted, not taken from the headers) would
// leave less than unzipKeepFree on the disk, and writes every file 0600:
// the zip's own modes could make a blob the relay can't read.
func UnzipDirectory(archive, dest string) error {
	return UnzipDirectoryCapped(archive, dest, 0, unzipMaxEntries)
}

// UnzipDirectoryCapped is UnzipDirectory with a byte cap (0 = only the free
// space) and an entry cap, for archives from strangers: a 256 MB deflate
// bomb would otherwise fill the disk to unzipKeepFree while the relay writes
// to the same disk.
func UnzipDirectoryCapped(archive, dest string, maxBytes uint64, maxEntries int) error {
	if maxEntries <= 0 || maxEntries > unzipMaxEntries {
		maxEntries = unzipMaxEntries
	}
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer reader.Close()

	dest = filepath.Clean(dest)
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return err
	}
	if len(reader.File) > maxEntries {
		return fmt.Errorf("archive has %d entries, more than %d", len(reader.File), maxEntries)
	}
	budget := uint64(unzipFallbackCap)
	if free, ok := unzipFreeBytes(dest); ok {
		if free <= unzipKeepFree {
			return errUnzipTooBig
		}
		budget = free - unzipKeepFree
	}
	if maxBytes > 0 && maxBytes < budget {
		budget = maxBytes
	}

	var written uint64
	for _, file := range reader.File {
		path := filepath.Join(dest, file.Name)

		// Check for ZipSlip vulnerability
		if !strings.HasPrefix(path, filepath.Clean(dest)+string(os.PathSeparator)) && path != dest {
			return fmt.Errorf("illegal file path: %s", path)
		}

		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o700); err != nil {
				return err
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}

		dstFile, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}

		srcFile, err := file.Open()
		if err != nil {
			dstFile.Close()
			return err
		}

		// One byte past the budget says the archive doesn't fit.
		n, err := io.Copy(dstFile, io.LimitReader(srcFile, int64(budget-written)+1))
		dstFile.Close()
		srcFile.Close()
		written += uint64(n)

		if err != nil {
			return err
		}
		if written > budget {
			_ = os.Remove(path)
			return errUnzipTooBig
		}
	}

	return nil
}
