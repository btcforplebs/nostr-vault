//go:build wasm

package main

import (
	"context"

	"github.com/fiatjaf/khatru/blossom"
)

// blobSpool: unset on the web vault, so khatru's memory spool is used.
var blobSpool func(context.Context) (blossom.Spool, error)
