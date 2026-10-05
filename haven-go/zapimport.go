package main

import (
	"encoding/json"

	"github.com/nbd-wtf/go-nostr"
)

// Zap receipts (kind 9735) are signed by the zapped person's lightning
// service, not by whoever zapped. Judging one by its author (the inbox rule
// for everything else) put every receipt outside the Web of Trust, so none
// was ever imported and the Relay tab's zaps were empty. The person behind a
// zap is the author of the signed zap request (kind 9734) the receipt
// carries in its description tag.

// zapRequestAuthor returns the author of the zap request inside receipt ev,
// or "" when ev is not a receipt or the request is missing, malformed or
// not validly signed.
func zapRequestAuthor(ev *nostr.Event) string {
	if ev.Kind != nostr.KindZap {
		return ""
	}
	desc := ev.Tags.Find("description")
	if len(desc) < 2 {
		return ""
	}
	var req nostr.Event
	if err := json.Unmarshal([]byte(desc[1]), &req); err != nil || req.Kind != nostr.KindZapRequest {
		return ""
	}
	if ok, err := req.CheckSignature(); err != nil || !ok {
		return ""
	}
	return req.PubKey
}

// inboxTrustKey is the key whose standing (blacklist, Web of Trust) decides
// whether a tagged event gets into the inbox: the zapper for a zap receipt,
// the author for everything else.
func inboxTrustKey(ev *nostr.Event) string {
	if sender := zapRequestAuthor(ev); sender != "" {
		return sender
	}
	return ev.PubKey
}

// givenZapSender returns the whitelisted account that sent the zap receipt ev
// is for: a `P` tag naming that account, and a zap request it signed. "" for
// anything else. These receipts tag the person zapped with `p`, so the inbox
// rules alone would never keep them.
func givenZapSender(ev *nostr.Event) string {
	if ev.Kind != nostr.KindZap {
		return ""
	}
	sender := zapRequestAuthor(ev)
	if sender == "" {
		return ""
	}
	if _, ok := config.WhitelistedPubKeys[sender]; !ok {
		return ""
	}
	for tag := range ev.Tags.FindAll("P") {
		if len(tag) >= 2 && tag[1] == sender {
			return sender
		}
	}
	return ""
}

// givenZapsFilter asks for receipts of zaps the whitelisted accounts sent.
func givenZapsFilter(pTags []string, since *nostr.Timestamp) nostr.Filter {
	return nostr.Filter{Kinds: []int{nostr.KindZap}, Tags: nostr.TagMap{"P": pTags}, Since: since}
}
