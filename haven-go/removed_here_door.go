package main

// The mesh door half of "Delete from this device" (Media list A3/D3).
//
// The app puts a removed file's hash on removed_here.json in the relay data
// folder (copyv2_removed_here.go reads it; the copy v2 catch-up skips it).
// One more engine path would put the file straight back: the mesh door's
// PUT /upload, where a paired phone's queue (HomeVaultSender) delivers
// uploads made there once this device is in reach. This refuses those.
//
// The explicit Save to Vault goes through the local port, not the mesh
// door, and the app takes the hash off the list first, so nothing here
// blocks it.

import (
	"context"

	"github.com/nbd-wtf/go-nostr"
)

// blobRemovedHere refuses, over the mesh door only, a blob the owner
// removed from this device (under any account: the vault folder is
// shared). 403 is final for the senders, so a paired phone's queue drops it
// instead of retrying.
func blobRemovedHere(ctx context.Context, _ *nostr.Event, sha string, _ int) (bool, string, int) {
	if ctx.Value(meshPeerKey{}) == nil || !copyIsRemovedHere(sha) {
		return false, "", 0
	}
	return true, "removed from this device", 403
}
