package main

// inboxRelays is the deduplicated relay set the inbox is pulled from and
// subscribed to: ImportSeedRelays + DmRelays + the Mac relay's inbox.
func inboxRelays() []string {
	relaySet := make(map[string]struct{})
	for _, r := range config.ImportSeedRelays {
		relaySet[r] = struct{}{}
	}
	for _, r := range config.DmRelays {
		relaySet[r] = struct{}{}
	}
	// The Mac relay's inbox is inbox-only, like a DM relay. (Its outbox is
	// already a seed relay: loadConfig adds it from MAC_RELAY_URL.)
	if _, macInbox := macRelayURLs(); macInbox != "" {
		relaySet[macInbox] = struct{}{}
	}
	relays := make([]string, 0, len(relaySet))
	for r := range relaySet {
		relays = append(relays, r)
	}
	return relays
}
