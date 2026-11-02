package main

import (
	"encoding/json"

	"github.com/nbd-wtf/go-nostr"
)

// The user's lists the vault keeps old versions of (list_history.go), so a
// wipe by any app can be undone (RESEARCH/NV_LIST_PROTECTION_PLAN.md, Logen
// 2026-11-02). One place: the apps mirror this set.
// Kind 0 is not a list but is kept the same way (Logen 2026-11-02): its
// items are the profile's filled-in fields.
var protectedListKinds = map[int]struct{}{
	0:     {}, // profile
	3:     {}, // follows
	10000: {}, // mutes
	10001: {}, // pinned notes
	10002: {}, // relay list
	10003: {}, // bookmarks
	10004: {}, // communities
	10006: {}, // blocked relays
	10007: {}, // search relays
	10015: {}, // interests
	10030: {}, // emoji list
	10050: {}, // DM relays
	10063: {}, // media servers
	30000: {}, // follow sets
	30002: {}, // relay sets
	30003: {}, // bookmark sets
}

// Lists whose private items are encrypted into the content, which the vault
// cannot read: for these a large drop in content length also counts.
var encryptedListKinds = map[int]struct{}{10000: {}, 10003: {}, 30000: {}, 30003: {}}

func isProtectedListKind(kind int) bool {
	_, ok := protectedListKinds[kind]
	return ok
}

// Tags that describe a list rather than being an item in it.
var listMetadataTags = map[string]struct{}{
	"d": {}, "title": {}, "name": {}, "description": {}, "image": {}, "alt": {}, "client": {},
}

// listItemCount is the number of public items in a list: every tag except
// the ones naming or describing the list itself. For a profile, the fields
// with a value.
func listItemCount(ev *nostr.Event) int {
	if ev.Kind == 0 {
		return profileFieldCount(ev.Content)
	}
	n := 0
	for _, t := range ev.Tags {
		if len(t) == 0 {
			continue
		}
		if _, meta := listMetadataTags[t[0]]; meta {
			continue
		}
		n++
	}
	return n
}

// profileFieldCount counts a kind 0's fields that hold something; content
// that is not a JSON object counts as empty.
func profileFieldCount(content string) int {
	var fields map[string]any
	if json.Unmarshal([]byte(content), &fields) != nil {
		return 0
	}
	n := 0
	for _, v := range fields {
		switch x := v.(type) {
		case nil:
		case string:
			if x != "" {
				n++
			}
		default:
			n++
		}
	}
	return n
}

const (
	// A list this size or larger alarms when it loses more than half.
	shrinkMinItems = 10
	// The same for the encrypted part, in characters of content (about ten
	// items of NIP-44 ciphertext).
	shrinkMinContent = 1000
)

// listShrank reports whether next, the version that replaced prev, looks
// like a wipe rather than an edit: it is empty where prev was not, or it
// kept fewer than half of a list of shrinkMinItems or more. For lists with
// an encrypted part the content counts the same way, by length. A grow, or
// an edit of a small list, is never a shrink.
func listShrank(prev, next *nostr.Event) bool {
	if prev == nil || next == nil {
		return false
	}
	oldItems, newItems := listItemCount(prev), listItemCount(next)
	if oldItems > 0 && newItems == 0 {
		return true
	}
	if oldItems >= shrinkMinItems && newItems*2 < oldItems {
		return true
	}
	if _, enc := encryptedListKinds[prev.Kind]; enc {
		oldLen, newLen := len(prev.Content), len(next.Content)
		if oldLen > 0 && newLen == 0 {
			return true
		}
		if oldLen >= shrinkMinContent && newLen*2 < oldLen {
			return true
		}
	}
	return false
}

// shrinkLookback is how many versions before a new one it is compared with,
// so a list emptied in steps (40, 20, 10, 5: each at least half the one
// before) still counts as wiped against the largest recent copy (Logen
// 2026-11-02, misses #2).
const shrinkLookback = 5

// listWiped reports whether next is a new wipe: it shrank (listShrank)
// against one of the up to shrinkLookback versions in older (the ones before
// it, nearest first), and no version in between already shrank against that
// same one. The second part keeps the edits right after a wipe from counting
// as wipes of their own against the list the wipe already pinned. A slow tidy
// that removes a few items at a time stays an edit: it takes more than
// shrinkLookback steps to lose half.
func listWiped(older []*nostr.Event, next *nostr.Event) bool {
	return listWipedAgainst(older, next) >= 0
}

// listWipedAgainst is listWiped, giving the index in older of the version
// next is a wipe of, or -1 when it is not a wipe.
func listWipedAgainst(older []*nostr.Event, next *nostr.Event) int {
	for i := 0; i < len(older) && i < shrinkLookback; i++ {
		if !listShrank(older[i], next) {
			continue
		}
		explained := false
		for j := 0; j < i; j++ {
			if listShrank(older[i], older[j]) {
				explained = true
				break
			}
		}
		if !explained {
			return i
		}
	}
	return -1
}

// listItems is the set of a list's public items by (name, value), or for a
// profile its filled-in fields by (field, value).
func listItems(ev *nostr.Event) map[string]struct{} {
	items := map[string]struct{}{}
	if ev.Kind == 0 {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(ev.Content), &fields) != nil {
			return items
		}
		for k, v := range fields {
			if val := string(v); val != "null" && val != `""` {
				items[k+"\x00"+val] = struct{}{}
			}
		}
		return items
	}
	for _, t := range ev.Tags {
		if len(t) == 0 {
			continue
		}
		if _, meta := listMetadataTags[t[0]]; meta {
			continue
		}
		key := t[0]
		if len(t) > 1 {
			key += "\x00" + t[1]
		}
		items[key] = struct{}{}
	}
	return items
}

// listHolds reports whether ev still holds everything in than: every public
// item and, for an encrypted list, at least as long a content. Only then is
// a version pinned before a wipe let go (restored, or rebuilt by hand). A
// list refilled to the same size with other items does not count. The
// vault can't read an encrypted part, so there a newer content at least as
// long counts as holding it: a refill of the private part to the same
// length lets the pin go.
func listHolds(ev *nostr.Event, evItems, thanItems map[string]struct{}, than *nostr.Event) bool {
	for k := range thanItems {
		if _, ok := evItems[k]; !ok {
			return false
		}
	}
	if _, enc := encryptedListKinds[than.Kind]; enc && len(ev.Content) < len(than.Content) {
		return false
	}
	return true
}
