package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// run sends one REQ or COUNT and returns the event ids served, the count a
// COUNT answered, and how it ended: "EOSE", "COUNT", or the CLOSED reason.
func (w *liveWS) run(verb string, filter map[string]any) (ids []string, count int64, end string) {
	w.t.Helper()
	w.send([]any{verb, "q", filter})
	deadline := time.Now().Add(5 * time.Second)
	for {
		label, arr := w.read(deadline)
		switch label {
		case "":
			w.t.Fatalf("%s %v: no answer", verb, filter)
		case "EVENT":
			var ev nostr.Event
			if len(arr) > 2 && json.Unmarshal(arr[2], &ev) == nil {
				ids = append(ids, ev.ID)
			}
		case "EOSE", "COUNT":
			if label == "COUNT" && len(arr) > 2 {
				var body struct {
					Count int64 `json:"count"`
				}
				_ = json.Unmarshal(arr[2], &body)
				count = body.Count
			}
			w.send([]any{"CLOSE", "q"})
			return ids, count, label
		case "CLOSED":
			var why string
			_ = json.Unmarshal(arr[2], &why)
			return ids, 0, why
		}
	}
}

// Someone in the web may read the chat relay, but only their own messages:
// they cannot list the gift wraps addressed to the vault's accounts. Runs
// against a real relay over websockets.
func TestChatRelayServesOnlyYourOwnMessages(t *testing.T) {
	skipWithoutSockets(t)
	h := startHaven(t)
	friendSK := nostr.GeneratePrivateKey()
	friend, _ := nostr.GetPublicKey(friendSK)
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{h.owner: true, friend: true}})

	wrap := func(to string) *nostr.Event {
		ev := &nostr.Event{Kind: nostr.KindGiftWrap, CreatedAt: nostr.Now() - 10, Tags: nostr.Tags{{"p", to}}, Content: "sealed"}
		if err := ev.Sign(nostr.GeneratePrivateKey()); err != nil { // a throwaway key, as NIP-59 does
			t.Fatal(err)
		}
		return ev
	}
	toOwner, toFriend := wrap(h.owner), wrap(friend)
	saveAll(t, chatDB, toOwner, toFriend)

	url := h.base + "/chat"
	wraps := func(extra map[string]any) map[string]any {
		f := map[string]any{"kinds": []int{nostr.KindGiftWrap}}
		for k, v := range extra {
			f[k] = v
		}
		return f
	}

	theirs := dialLive(t, url)
	if !theirs.auth(friendSK, url) {
		t.Fatal("the friend's AUTH was not taken")
	}
	for name, filter := range map[string]map[string]any{
		"every wrap":                    wraps(nil),
		"the owner's wraps":             wraps(map[string]any{"#p": []string{h.owner}}),
		"theirs and the owner's":        wraps(map[string]any{"#p": []string{friend, h.owner}}),
		"by the owner as author":        wraps(map[string]any{"authors": []string{h.owner}}),
		"the owner's wrap by id":        {"ids": []string{toOwner.ID}},
		"theirs, plus another's author": wraps(map[string]any{"authors": []string{friend, toOwner.PubKey}}),
	} {
		if ids, _, end := theirs.run("REQ", filter); len(ids) != 0 || !strings.HasPrefix(end, "restricted") {
			t.Errorf("friend, REQ %s: served %d, ended %q; want refused", name, len(ids), end)
		}
		// A refused COUNT is answered with a notice and a count of 0.
		if _, n, _ := theirs.run("COUNT", filter); n != 0 {
			t.Errorf("friend, COUNT %s: counted %d, want 0", name, n)
		}
	}
	if ids, _, end := theirs.run("REQ", wraps(map[string]any{"#p": []string{friend}})); end != "EOSE" || len(ids) != 1 || ids[0] != toFriend.ID {
		t.Errorf("friend asking for their own wraps: served %v, ended %q; want their one wrap", ids, end)
	}
	if _, n, _ := theirs.run("COUNT", wraps(map[string]any{"#p": []string{friend}})); n != 1 {
		t.Errorf("friend counting their own wraps got %d, want 1", n)
	}

	// A live subscription for their own wraps is not sent the owner's.
	theirs.send([]any{"REQ", "live", wraps(map[string]any{"#p": []string{friend}, "limit": 0})})
	theirs.waitFor("EOSE")
	writer := dialLive(t, url)
	if !writer.auth(h.ownerSK, url) {
		t.Fatal("the owner's AUTH was not taken")
	}
	fresh := wrap(h.owner)
	fresh.CreatedAt = nostr.Now()
	_ = fresh.Sign(nostr.GeneratePrivateKey())
	if ok, msg := writer.publish(*fresh); !ok {
		t.Fatalf("the owner's write was refused: %q", msg)
	}
	if theirs.gotEvent(time.Second) {
		t.Error("the friend's live subscription was sent a wrap addressed to the owner")
	}

	// Your own account reads everything, as before.
	ids, _, end := writer.run("REQ", wraps(nil))
	if end != "EOSE" || len(ids) != 3 {
		t.Errorf("the owner read %d wraps (ended %q), want all 3", len(ids), end)
	}
	if _, n, _ := writer.run("COUNT", wraps(nil)); n != 3 {
		t.Errorf("the owner counted %d wraps, want 3", n)
	}
}

func TestMustReadOnlyOwnChat(t *testing.T) {
	own, other, added, reader := hexid('a'), hexid('b'), hexid('d'), hexid('c')
	setupSyncConfig(own)
	config.WhitelistedPubKeys[other] = struct{}{} // a second account with its key here
	config.WhitelistedPubKeys[added] = struct{}{} // a watch-only added npub: no key here
	config.PrivateReaderPubKeys = map[string]struct{}{own: {}, other: {}}
	p := func(pks ...string) nostr.Filter { return nostr.Filter{Tags: nostr.TagMap{"p": pks}} }
	for name, c := range map[string]struct {
		as     string
		filter nostr.Filter
		reject bool
	}{
		"own account, anything":          {own, nostr.Filter{}, false},
		"own account, another account's": {other, p(own), false},
		"added npub, an account's wraps": {added, p(own), true},
		"added npub, anything":           {added, nostr.Filter{}, true},
		"added npub, its own wraps":      {added, p(added), false},
		"reader, own wraps":              {reader, p(reader), false},
		"reader, own events":             {reader, nostr.Filter{Authors: []string{reader}}, false},
		"reader, nothing named":          {reader, nostr.Filter{}, true},
		"reader, an account's wraps":     {reader, p(own), true},
		"reader, theirs and an account":  {reader, p(reader, own), true},
		"reader, an account as author":   {reader, nostr.Filter{Authors: []string{own}}, true},
		"nobody signed in":               {"", p(own), true},
		"nobody signed in, empty p":      {"", p(""), true},
	} {
		if reject, _ := MustReadOnlyOwnChat(authedAs(c.as), c.filter); reject != c.reject {
			t.Errorf("%s: reject = %v, want %v", name, reject, c.reject)
		}
	}
}
