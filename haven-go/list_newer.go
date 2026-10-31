package main

import (
	"context"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// A user's list (follows, relays, media servers, interests, ...) is a
// replaceable event: only the newest copy counts, and sending an older one
// again can undo an edit made since on another device. The vault never signs
// a list itself, but it re-sends copies it holds (the blast retry queue and
// the negentropy upload). Before it does, it checks for a newer copy, and it
// does not send when nobody answered the check: one relay with no answer is
// not "there is nothing newer".

// isUserList reports whether only the newest copy of ev's kind counts.
func isUserList(ev *nostr.Event) bool {
	return nostr.IsReplaceableKind(ev.Kind) || nostr.IsAddressableKind(ev.Kind)
}

// listFilter finds every copy of the list ev is one copy of.
func listFilter(ev *nostr.Event) nostr.Filter {
	f := nostr.Filter{Kinds: []int{ev.Kind}, Authors: []string{ev.PubKey}}
	if nostr.IsAddressableKind(ev.Kind) {
		f.Tags = nostr.TagMap{"d": []string{ev.Tags.GetD()}}
	}
	return f
}

// supersedes reports whether other replaces ev (NIP-01: newer created_at,
// and on a tie the lower id).
func supersedes(other, ev *nostr.Event) bool {
	if other.ID == ev.ID {
		return false
	}
	return other.CreatedAt > ev.CreatedAt || (other.CreatedAt == ev.CreatedAt && other.ID < ev.ID)
}

// newerListInStore reports whether store holds a copy that replaces ev. A
// store that cannot be read counts as holding one: the caller must not send.
func newerListInStore(ctx context.Context, store eventQuerier, ev *nostr.Event) bool {
	if store == nil {
		return false
	}
	ch, err := store.QueryEvents(ctx, listFilter(ev))
	if err != nil {
		return true
	}
	newer := false
	for other := range ch {
		if supersedes(other, ev) {
			newer = true
		}
	}
	return newer
}

var listCheckTimeout = 10 * time.Second

// newerListOnRelays asks urls for ev's list. It reports whether any relay
// holds a copy that replaces ev and how many relays answered (EOSE). A var so
// tests can count calls.
var newerListOnRelays = func(ctx context.Context, urls []string, ev *nostr.Event) (newer bool, answered int) {
	ctx, cancel := context.WithTimeout(ctx, listCheckTimeout)
	defer cancel()
	answered = fetchAnswered(ctx, urls, listFilter(ev), func(re nostr.RelayEvent) {
		if re.Event.PubKey == ev.PubKey && re.Event.Kind == ev.Kind && supersedes(re.Event, ev) {
			if !nostr.IsAddressableKind(ev.Kind) || re.Event.Tags.GetD() == ev.Tags.GetD() {
				if ok, _ := re.Event.CheckSignature(); ok && re.Event.CheckID() {
					newer = true
				}
			}
		}
	})
	return newer, answered
}

type listResend int

const (
	listSend    listResend = iota // nothing newer anywhere that answered
	listDrop                      // a newer copy exists: ours must never go out
	listNoCheck                   // nobody answered: do not send now, maybe later
)

// checkListResend decides whether a held copy of a list may be sent again.
// Events that are not lists always may.
func checkListResend(ctx context.Context, local eventQuerier, urls []string, ev *nostr.Event) listResend {
	if !isUserList(ev) {
		return listSend
	}
	if newerListInStore(ctx, local, ev) {
		return listDrop
	}
	if len(urls) == 0 {
		return listNoCheck
	}
	newer, answered := newerListOnRelays(ctx, urls, ev)
	switch {
	case newer:
		return listDrop
	case answered == 0:
		return listNoCheck
	}
	return listSend
}
