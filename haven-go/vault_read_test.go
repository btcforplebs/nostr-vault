package main

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// The Vault tab's direct read (vault_read.go) answers what the socket's /
// and /inbox would: outbox and inbox only, one copy per event, newest first,
// with blocked people and brought-over accounts hidden.
func TestVaultReadServesWhatTheSocketWould(t *testing.T) {
	skipWithoutSockets(t)
	h := startHaven(t)
	t.Cleanup(func() { blacklistOverride.Store(nil) })
	now := time.Now().Unix()
	key := func() (string, string) {
		sk := nostr.GeneratePrivateKey()
		pk, _ := nostr.GetPublicKey(sk)
		return sk, pk
	}
	blockedSK, blocked := key()
	broughtSK, brought := key()
	friendSK, _ := key()

	mine := signedAt(t, h.ownerSK, 1, "my note", now-100)
	reply := signedAt(t, friendSK, 1, "a reply to you", now-50)
	reply.Tags = nostr.Tags{{"p", h.owner}}
	if err := reply.Sign(friendSK); err != nil {
		t.Fatal(err)
	}
	blockedNote := signedAt(t, blockedSK, 1, "blocked note", now-200)
	broughtNote := signedAt(t, broughtSK, 1, "brought-over note", now-300)
	secret := signedAt(t, h.ownerSK, 1, "private note", now-10)
	blockedReply := signedAt(t, blockedSK, 1, "blocked reply", now-60)
	blockedReply.Tags = nostr.Tags{{"p", h.owner}}
	if err := blockedReply.Sign(blockedSK); err != nil {
		t.Fatal(err)
	}
	saveAll(t, outboxDB, mine, blockedNote, broughtNote)
	saveAll(t, inboxDB, reply, mine, blockedReply) // mine in both: one copy back
	saveAll(t, privateDB, secret)

	outbox, inbox, closing := vaultQueriesFor(outboxDB, inboxDB)
	read := func(t *testing.T) []*nostr.Event {
		t.Helper()
		evs, err := readVault(context.Background(), vaultReadRequest{Filters: []nostr.Filter{{Kinds: []int{1}}}}, outbox, inbox, closing)
		if err != nil {
			t.Fatal(err)
		}
		return evs
	}
	ids := func(evs []*nostr.Event) map[string]bool {
		m := map[string]bool{}
		for _, ev := range evs {
			m[ev.ID] = true
		}
		return m
	}

	// Positive control: before the block and the brought record, all show.
	if got := ids(read(t)); !got[blockedReply.ID] || !got[blockedNote.ID] || !got[broughtNote.ID] || !got[mine.ID] || !got[reply.ID] {
		t.Fatalf("before: %v", got)
	}

	UpdateBlacklist(map[string]struct{}{blocked: {}})
	npub, _ := nip19.EncodePublicKey(brought)
	raw, _ := json.Marshal(copyBroughtList{V: 1, Accounts: []string{npub}})
	if err := os.WriteFile(copyBroughtFile, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(copyBroughtFile) })

	evs := read(t)
	got := ids(evs)
	if got[blockedNote.ID] || got[blockedReply.ID] {
		t.Fatal("blocked person's note read")
	}
	if got[broughtNote.ID] {
		t.Fatal("brought-over account's note read")
	}
	if got[secret.ID] {
		t.Fatal("private store read")
	}
	if !got[mine.ID] || !got[reply.ID] || len(evs) != 2 {
		t.Fatalf("want my note + the reply once each, got %d: %v", len(evs), got)
	}
	if evs[0].ID != reply.ID {
		t.Fatal("not newest first")
	}
}

func TestVaultReadNotReadyFallsBackToTheSocket(t *testing.T) {
	if relayLC.current.Load() != nil {
		t.Skip("a relay cycle is live in this binary")
	}
	var a vaultReadAnswer
	if err := json.Unmarshal(queryVault(`{"filters":[{"kinds":[1]}]}`), &a); err != nil {
		t.Fatal(err)
	}
	if a.Error != errVaultReadNotReady.Error() {
		t.Fatalf("no cycle: error %q", a.Error)
	}
}

// A read a stop cut off returns part of the rows with no error: closing
// means not ready, never a short list.
func TestVaultReadCutOffByAStopIsNotReady(t *testing.T) {
	empty := func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event)
		close(ch)
		return ch, nil
	}
	_, err := readVault(context.Background(), vaultReadRequest{Filters: []nostr.Filter{{Kinds: []int{1}}}}, empty, empty, func() bool { return true })
	if err != errVaultReadNotReady {
		t.Fatalf("closing: %v", err)
	}
	if _, err := readVault(context.Background(), vaultReadRequest{}, empty, empty, func() bool { return false }); err == nil {
		t.Fatal("no filters accepted")
	}
	if _, err := readVault(context.Background(), vaultReadRequest{Filters: []nostr.Filter{{Search: "x"}}}, empty, empty, func() bool { return false }); err == nil {
		t.Fatal("search accepted")
	}
}

// Each filter's limit is capped, a missing one included.
func TestVaultReadCapsTheLimit(t *testing.T) {
	var asked []int
	q := func(_ context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		asked = append(asked, f.Limit)
		ch := make(chan *nostr.Event)
		close(ch)
		return ch, nil
	}
	_, err := readVault(context.Background(), vaultReadRequest{Filters: []nostr.Filter{{Limit: 0}, {Limit: 400}, {Limit: 100000}}}, q, q, func() bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	want := []int{vaultReadMaxLimit, vaultReadMaxLimit, 400, 400, vaultReadMaxLimit, vaultReadMaxLimit}
	for i := range want {
		if asked[i] != want[i] {
			t.Fatalf("limits asked %v, want %v", asked, want)
		}
	}
}
