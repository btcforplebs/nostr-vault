//go:build !wasm

package main

import (
	"context"

	"github.com/fiatjaf/khatru/blossom"
)

// blobSpool: natively a blob streams into a temp file (fileSpool).
func blobSpool(context.Context) (blossom.Spool, error) { return newFileSpool(fs) }
