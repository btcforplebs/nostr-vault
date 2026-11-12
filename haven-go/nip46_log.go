package main

import (
	"fmt"

	"github.com/nbd-wtf/go-nostr"
)

// nip46SignLogLine is the relay log line for a sign request sent to a bunker.
func nip46SignLogLine(event *nostr.Event) string {
	pubPrefix := event.PubKey
	if len(pubPrefix) > 8 {
		pubPrefix = pubPrefix[:8]
	}
	return fmt.Sprintf("NIP46SignEventC: sending sign_event to bunker kind=%d pubkey=%s tags=%v", event.Kind, pubPrefix, event.Tags)
}
