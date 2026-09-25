package main

import (
	"fmt"
	"slices"

	"github.com/nbd-wtf/go-nostr"
)

// checkRemoteSigned accepts an event a remote signer returned only if it is
// the event we asked it to sign, signed by the key we expected. A valid
// signature alone proves nothing about identity: a bunker paired to another
// account returns a perfectly valid event under the wrong pubkey.
func checkRemoteSigned(req, got nostr.Event, wantPubkey string) error {
	if got.PubKey != wantPubkey {
		return fmt.Errorf("signer returned pubkey %.8s, expected %.8s", got.PubKey, wantPubkey)
	}
	if got.Kind != req.Kind || got.CreatedAt != req.CreatedAt || got.Content != req.Content {
		return fmt.Errorf("signer changed kind, created_at or content")
	}
	if !slices.EqualFunc(got.Tags, req.Tags, func(a, b nostr.Tag) bool { return slices.Equal(a, b) }) {
		return fmt.Errorf("signer changed tags")
	}
	if !got.CheckID() {
		return fmt.Errorf("signer returned a mismatched id")
	}
	if ok, err := got.CheckSignature(); !ok {
		return fmt.Errorf("signer returned an invalid signature: %v", err)
	}
	return nil
}
