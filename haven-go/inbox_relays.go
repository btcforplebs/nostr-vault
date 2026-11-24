package main

// inboxRelays is the deduplicated relay set the inbox is pulled from and
// subscribed to: ImportSeedRelays + DmRelays + every desktop Vault's inbox.
func inboxRelays() []string {
	relaySet := make(map[string]struct{})
	for _, r := range config.ImportSeedRelays {
		relaySet[r] = struct{}{}
	}
	for _, r := range config.DmRelays {
		relaySet[r] = struct{}{}
	}
	// A desktop Vault's inbox is inbox-only, like a DM relay. (Its outbox is
	// already a seed relay: loadConfig adds every Vault's base.)
	for _, v := range desktopVaults() {
		relaySet[v.inbox] = struct{}{}
	}
	relays := make([]string, 0, len(relaySet))
	for r := range relaySet {
		relays = append(relays, r)
	}
	return relays
}
