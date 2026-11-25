//go:build !(js && wasm)

package main

// A first copy the other device stopped on its held token (token_refused,
// or auth_refused before 2026-11-25) left the app with no pending copy and
// no catch-up: that device's trust rank never came over. copyRefusedPeers
// lets the app start it again, signed by this device's mesh key.

import (
	"os"
	"path/filepath"
	"sort"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// copyRefusedPeers: paired devices this one holds a copy token from with no
// first copy or catch-up finished, and an empty copy folder (run() wipes it
// before it gives up for want of a new start). A folder holding a state is
// a copy still to resume; one holding copyStartFailedFile was turned down
// on a new start too. As sorted npubs.
func copyRefusedPeers() []string {
	copyPeersMu.Lock()
	tokens := loadCopyPeers()
	copyPeersMu.Unlock()
	copySyncMu.Lock()
	marks := loadCopySync()
	copySyncMu.Unlock()
	out := []string{}
	for _, hex := range meshDevices.pairedKeys() {
		npub, err := nip19.EncodePublicKey(hex)
		if err != nil {
			continue
		}
		for _, name := range []string{npub, hex} {
			key := copyPeerKey(name)
			if tokens[key] == "" || marks[key] > 0 || marks[copyPeerKey(name+copyDoneMark)] > 0 {
				continue
			}
			if entries, err := os.ReadDir(filepath.Join(copyInDir, key)); err == nil && len(entries) == 0 {
				out = append(out, npub)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}
