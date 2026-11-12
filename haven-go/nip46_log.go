package main

import (
	"fmt"

	"github.com/nbd-wtf/go-nostr"
)

// nip46SignLogLine is the relay log line for a sign request sent to a bunker.
// The tag count, not the tags: a follow list's tags made one line of hundreds
// of KB, and the Mac app parses every relay log line (2026-11-12).
func nip46SignLogLine(event *nostr.Event) string {
	pubPrefix := event.PubKey
	if len(pubPrefix) > 8 {
		pubPrefix = pubPrefix[:8]
	}
	return fmt.Sprintf("NIP46SignEventC: sending sign_event to bunker kind=%d pubkey=%s tags=%d", event.Kind, pubPrefix, len(event.Tags))
}
