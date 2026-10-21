//go:build !cshared

package main

import (
	"context"
	"testing"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// A block hides what the person already stored, on every read, and unblocking
// brings it back. Runs against a real relay (startHaven) over websockets.
func TestBlockedAuthorsAreNotServed(t *testing.T) {
	skipWithoutSockets(t)
	h := startHaven(t)
	t.Cleanup(func() { blacklistOverride.Store(nil) })
	now := time.Now().Unix()
	blockedSK := nostr.GeneratePrivateKey()
	blocked, _ := nostr.GetPublicKey(blockedSK)
	friendSK := nostr.GeneratePrivateKey()
	friend, _ := nostr.GetPublicKey(friendSK)

	mine := signedAt(t, h.ownerSK, 1, "my bitcoin note", now-100)
	theirs := signedAt(t, blockedSK, 1, "their bitcoin note", now-200)
	friends := signedAt(t, friendSK, 1, "a friend's bitcoin note", now-300)
	saveAll(t, outboxDB, mine, theirs, friends)
	outbox := h.connect(t, "")
	notes := nostr.Filter{Kinds: []int{1}}

	served := func(t *testing.T, f nostr.Filter) map[string]bool {
		t.Helper()
		got, closed := req(t, outbox, f)
		if closed != "" {
			t.Fatalf("closed: %s", closed)
		}
		return idSet(got)
	}

	// Positive control: before the block, everyone's notes are served.
	if ids := served(t, notes); !ids[mine.ID] || !ids[theirs.ID] || !ids[friends.ID] {
		t.Fatalf("before block: want all three, got %v", ids)
	}

	UpdateBlacklist(map[string]struct{}{blocked: {}})

	t.Run("hidden from a plain REQ", func(t *testing.T) {
		ids := served(t, notes)
		if ids[theirs.ID] {
			t.Fatal("blocked author's stored note was served")
		}
		if !ids[mine.ID] || !ids[friends.ID] {
			t.Fatalf("others must still be served, got %v", ids)
		}
	})

	t.Run("hidden when asked for by author", func(t *testing.T) {
		if ids := served(t, nostr.Filter{Authors: []string{blocked}}); len(ids) != 0 {
			t.Fatalf("got %v", ids)
		}
		if ids := served(t, nostr.Filter{Authors: []string{friend}}); !ids[friends.ID] {
			t.Fatal("friend's note asked for by author was not served")
		}
	})

	t.Run("hidden from search", func(t *testing.T) {
		ids := served(t, nostr.Filter{Kinds: []int{1}, Search: "bitcoin"})
		if ids[theirs.ID] || !ids[friends.ID] {
			t.Fatalf("search: got %v", ids)
		}
	})

	t.Run("left out of COUNT", func(t *testing.T) {
		count := hideBlacklistedCount(searchableCount(outboxDB))
		if n, err := count(context.Background(), notes); err != nil || n != 2 {
			t.Fatalf("count = %d, %v; want 2", n, err)
		}
		if n, _ := count(context.Background(), nostr.Filter{Authors: []string{blocked}}); n != 0 {
			t.Fatalf("count by blocked author = %d, want 0", n)
		}
	})

	t.Run("negentropy sync still sees everything", func(t *testing.T) {
		query := hideBlacklistedQuery(outboxDB.QueryEvents)
		ch, err := query(eventstore.SetNegentropy(context.Background()), notes)
		if err != nil {
			t.Fatal(err)
		}
		var ids = map[string]bool{}
		for ev := range ch {
			ids[ev.ID] = true
		}
		if !ids[theirs.ID] {
			t.Fatal("a negentropy session must get the full store")
		}
	})

	t.Run("your own account is never hidden", func(t *testing.T) {
		UpdateBlacklist(map[string]struct{}{blocked: {}, h.owner: {}})
		defer UpdateBlacklist(map[string]struct{}{blocked: {}})
		if ids := served(t, notes); !ids[mine.ID] {
			t.Fatal("owner's note was hidden")
		}
	})

	t.Run("unblock serves it again", func(t *testing.T) {
		UpdateBlacklist(map[string]struct{}{})
		if ids := served(t, notes); !ids[theirs.ID] {
			t.Fatal("unblocked author's note was not served")
		}
	})
}
