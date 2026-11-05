//go:build cshared

package main

import "C"

import (
	"context"
	"log/slog"
)

// ImportOwnerBlobC stores the file at path in the vault's Blossom store as
// the owner's, with no signature (owner_blob_import.go). 1 when it is there
// now (stored, or already there), 0 when refused.
//
//export ImportOwnerBlobC
func ImportOwnerBlobC(path *C.char, sha256 *C.char, mimeType *C.char) C.int {
	if err := importOwnerBlob(context.Background(), C.GoString(path), C.GoString(sha256), C.GoString(mimeType)); err != nil {
		slog.Warn("owner blob import refused", "sha256", C.GoString(sha256), "error", err)
		return 0
	}
	return 1
}
