//go:build !(js && wasm)

package main

import (
	"context"
	"testing"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

// Logen, 2026-11-06: an account the copy kept read only (brought over, keep
// list #1827) is normal again once the person signs in here as it, live
// (AddAccountsC) or at the next start (the whitelist file): its posts upload
// and the public outbox serves them. Removed again, it is read only again.
func TestBroughtAccountIsNormalAfterSigningIn(t *testing.T) {
	me, second := newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	if err := recordBroughtAccounts(copyAccountList{V: 1, Accounts: []copyAccount{{Npub: npubOf(t, second.pk)}}}); err != nil {
		t.Fatal(err)
	}
	note := second.sign(t, nostr.Event{Kind: 1, Content: "second's new post"})
	saveEv(t, outboxDB, note)

	uploads := func() bool {
		s := &outboxNegStore{outbox: eventstore.RelayWrapper{Store: outboxDB}, tombs: newTestTombs(t)}
		ch, err := s.QueryEvents(context.Background(), nostr.Filter{IDs: []string{note.ID}})
		if err != nil {
			t.Fatal(err)
		}
		got := false
		for ev := range ch {
			got = got || ev.ID == note.ID
		}
		return got
	}
	served := func() bool {
		query := hideBroughtQuery(func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
			return outboxDB.QueryEvents(ctx, f)
		})
		ch, err := query(context.Background(), nostr.Filter{Authors: []string{second.pk}})
		if err != nil {
			t.Fatal(err)
		}
		got := false
		for ev := range ch {
			got = got || ev.ID == note.ID
		}
		return got
	}
	if uploads() || served() {
		t.Fatal("a brought-over account's post uploads or is served before sign-in")
	}

	// Live sign-in.
	if addLiveAccounts([]string{second.pk}) != 1 {
		t.Fatal("sign-in did not add the account")
	}
	if _, b := broughtAccounts()[second.pk]; b {
		t.Fatal("still read only after signing in")
	}
	if !uploads() || !served() {
		t.Fatal("after sign-in its post does not upload or is not served")
	}

	// Next start: the whitelist file has it; same.
	resetLiveAccounts()
	config.WhitelistedPubKeys = map[string]struct{}{me.pk: {}, second.pk: {}}
	if _, b := broughtAccounts()[second.pk]; b || !uploads() {
		t.Fatal("read only again after a restart with it in the whitelist")
	}

	// Removed again: read only again.
	config.WhitelistedPubKeys = map[string]struct{}{me.pk: {}}
	if _, b := broughtAccounts()[second.pk]; !b || uploads() || served() {
		t.Fatal("a removed account's post uploads or is served")
	}
}
