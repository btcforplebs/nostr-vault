//go:build js && wasm

package main

import (
	"context"

	"github.com/nbd-wtf/go-nostr"
)

// The browser vault has no copy catch-up, so no delete list (copyv2_deletes.go).
func noteCopyDeleteAuth(context.Context, *nostr.Event, string, string) (bool, string, int) {
	return false, "", 0
}

func keepOwnCopyDelete(string) {}
