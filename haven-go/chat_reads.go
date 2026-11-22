package main

import (
	"context"
	"log/slog"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Who may read what on the chat relay. The web-of-trust gate
// (MustBeInWotToQuery) only says who may read at all; without this, anyone
// it let in could list every account's gift wraps: the contents stay
// encrypted, but who received messages, and when, was visible.
//
// The accounts with a key or signer on this device (privateReaders, the
// same set /private serves) read everything. Anyone else reads only what is
// theirs, and that includes a watch-only added account: an added npub is
// often someone else's, and whoever holds its key could AUTH as it
// (whitelist.go). They read only what is theirs: a filter whose #p names them and nobody
// else, or whose authors names them and nobody else. A filter that does not
// say so is refused rather than narrowed, so a client is told. The rule is on
// the filter, so it covers REQ, COUNT, negentropy (which all run these
// hooks) and the live feed of a subscription (it only matches its filter).

// onlyNames reports whether values is not empty and holds nothing but pubkey.
func onlyNames(values []string, pubkey string) bool {
	if len(values) == 0 {
		return false
	}
	for _, v := range values {
		if v != pubkey {
			return false
		}
	}
	return true
}

// MustReadOnlyOwnChat refuses a chat relay read by someone who is not a
// private reader unless it asks only for their own messages.
func MustReadOnlyOwnChat(ctx context.Context, filter nostr.Filter) (bool, string) {
	reader := khatru.GetAuthed(ctx)
	if reader != "" && isPrivateReader(reader) {
		return false, ""
	}
	if reader != "" && (onlyNames(filter.Tags["p"], reader) || onlyNames(filter.Authors, reader)) {
		return false, ""
	}
	slog.Debug("🚫 chat query rejected: not limited to the reader's own messages", "user", reader)
	return true, "restricted: you can only read messages addressed to you (#p must be your own pubkey)"
}
