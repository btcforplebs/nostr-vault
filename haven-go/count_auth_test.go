package main

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// connectWithNotices is connect plus a record of every NOTICE the relay sends.
func (h *havenUnderTest) connectWithNotices(t *testing.T, path string) (*nostr.Relay, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var notices []string
	r := nostr.NewRelay(context.Background(), h.base+path, nostr.WithNoticeHandler(func(n string) {
		mu.Lock()
		notices = append(notices, n)
		mu.Unlock()
	}))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), notices...)
	}
}

// authAs answers the relay's AUTH challenge with sk, retrying until the
// challenge has arrived. Returns the relay's verdict.
func authAs(t *testing.T, r *nostr.Relay, sk string) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var err error
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if err = r.Auth(ctx, func(ev *nostr.Event) error { return ev.Sign(sk) }); err == nil {
			return nil
		}
	}
	return err
}

func countOn(t *testing.T, r *nostr.Relay, f nostr.Filter) int64 {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	n, _, err := r.Count(ctx, nostr.Filters{f})
	if err != nil {
		t.Fatalf("COUNT %v: %v", f, err)
	}
	return n
}

func hasNoticePrefix(notices []string, prefix string) bool {
	for _, n := range notices {
		if strings.HasPrefix(n, prefix) {
			return true
		}
	}
	return false
}

// TestPrivateCountsNeedAuth: COUNT on /private and /chat is gated exactly like
// REQ. A stranger gets a NOTICE and 0 (khatru still sends the COUNT reply),
// the owner gets the real number. The outbox stays open.
func TestPrivateCountsNeedAuth(t *testing.T) {
	skipWithoutSockets(t)
	h := startHaven(t)
	now := time.Now().Unix()
	strangerSK := nostr.GeneratePrivateKey()

	saveAll(t, privateDB,
		signedAt(t, h.ownerSK, 1, "private one", now-10),
		signedAt(t, h.ownerSK, 1, "private two", now-20),
		signedAt(t, h.ownerSK, 1, "private three", now-30))
	saveAll(t, chatDB,
		signedAt(t, h.ownerSK, nostr.KindSimpleGroupChatMessage, "chat one", now-10),
		signedAt(t, h.ownerSK, nostr.KindSimpleGroupChatMessage, "chat two", now-20))
	saveAll(t, outboxDB, signedAt(t, h.ownerSK, 1, "public", now-10))

	routes := []struct {
		path      string
		want      int64
		strangerN string // NOTICE prefix for an authed stranger
	}{
		{"/private", 3, "restricted"},
		{"/chat", 2, "restricted"},
	}

	for _, rt := range routes {
		t.Run(rt.path+" without auth", func(t *testing.T) {
			r, notices := h.connectWithNotices(t, rt.path)
			for _, f := range []nostr.Filter{{}, {Kinds: []int{1, nostr.KindSimpleGroupChatMessage}}, {Authors: []string{h.owner}}} {
				if n := countOn(t, r, f); n != 0 {
					t.Fatalf("unauthenticated COUNT %v = %d, want 0", f, n)
				}
			}
			if !hasNoticePrefix(notices(), "auth-required") {
				t.Fatalf("want an auth-required NOTICE, got %q", notices())
			}
		})

		t.Run(rt.path+" as a stranger", func(t *testing.T) {
			r, notices := h.connectWithNotices(t, rt.path)
			if err := authAs(t, r, strangerSK); err != nil {
				t.Fatalf("stranger auth: %v", err)
			}
			if n := countOn(t, r, nostr.Filter{}); n != 0 {
				t.Fatalf("stranger COUNT = %d, want 0", n)
			}
			if !hasNoticePrefix(notices(), rt.strangerN) {
				t.Fatalf("want a %s NOTICE, got %q", rt.strangerN, notices())
			}
		})

		t.Run(rt.path+" as the owner", func(t *testing.T) {
			r, notices := h.connectWithNotices(t, rt.path)
			if err := authAs(t, r, h.ownerSK); err != nil {
				t.Fatalf("owner auth: %v", err)
			}
			if n := countOn(t, r, nostr.Filter{}); n != rt.want {
				t.Fatalf("owner COUNT = %d, want %d", n, rt.want)
			}
			if got := notices(); len(got) != 0 {
				t.Fatalf("owner got NOTICEs %q", got)
			}
		})
	}

	t.Run("outbox COUNT stays open", func(t *testing.T) {
		r, notices := h.connectWithNotices(t, "")
		if n := countOn(t, r, nostr.Filter{Kinds: []int{1}}); n != 1 {
			t.Fatalf("outbox COUNT = %d, want 1", n)
		}
		if got := notices(); len(got) != 0 {
			t.Fatalf("outbox got NOTICEs %q", got)
		}
	})
}
