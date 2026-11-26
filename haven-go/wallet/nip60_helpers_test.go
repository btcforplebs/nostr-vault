package wallet

// Test helpers for the NIP-60/61 layer: a throwaway account that signs and
// NIP-44-encrypts like the apps do, and an in-memory stand-in for the Vault
// /private relay.

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
)

type acct struct {
	sk, pk string
	ck     [32]byte
}

func newAcct(t testing.TB) acct {
	t.Helper()
	sk := nostr.GeneratePrivateKey()
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		t.Fatal(err)
	}
	ck, err := nip44.GenerateConversationKey(pk, sk)
	if err != nil {
		t.Fatal(err)
	}
	return acct{sk: sk, pk: pk, ck: ck}
}

// sign does what the app does with a Template: encrypt to self if asked,
// then sign.
func (a acct) sign(t testing.TB, tpl Template) nostr.Event {
	t.Helper()
	content := tpl.Content
	if tpl.Encrypt {
		var err error
		if content, err = nip44.Encrypt(tpl.Content, a.ck); err != nil {
			t.Fatal(err)
		}
	}
	ev := nostr.Event{Kind: tpl.Kind, CreatedAt: nostr.Timestamp(tpl.CreatedAt), Tags: tpl.Tags, Content: content}
	if ev.Tags == nil {
		ev.Tags = nostr.Tags{}
	}
	if err := ev.Sign(a.sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func (a acct) open(t testing.TB, ev nostr.Event) OwnEvent {
	t.Helper()
	pt, err := nip44.Decrypt(ev.Content, a.ck)
	if err != nil {
		t.Fatal(err)
	}
	return OwnEvent{Event: ev, Plaintext: pt}
}

// vault is the account's /private relay: it keeps everything, honours
// kind-5 deletions by the author, and keeps only the newest 17375.
type vault struct {
	events []nostr.Event
}

func (v *vault) add(ev nostr.Event) {
	if ev.Kind == KindWallet {
		kept := v.events[:0]
		for _, e := range v.events {
			if e.Kind != KindWallet || e.PubKey != ev.PubKey {
				kept = append(kept, e)
			}
		}
		v.events = kept
	}
	v.events = append(v.events, ev)
}

func (v *vault) live() []nostr.Event {
	gone := map[string]bool{}
	for _, e := range v.events {
		if e.Kind == KindDeletion {
			for _, t := range e.Tags {
				if len(t) >= 2 && t[0] == "e" {
					gone[t[1]] = true
				}
			}
		}
	}
	var out []nostr.Event
	for _, e := range v.events {
		if !gone[e.ID] {
			out = append(out, e)
		}
	}
	return out
}

func (v *vault) count(kind int) int {
	n := 0
	for _, e := range v.live() {
		if e.Kind == kind {
			n++
		}
	}
	return n
}

// publishPlan signs and stores every event in plan, committing each.
func (v *vault) publishPlan(t testing.TB, a acct, w *Wallet, plan RolloverPlan) {
	t.Helper()
	for _, tpl := range plan.Events {
		ev := a.sign(t, tpl)
		v.add(ev)
		if err := w.CommitPublished(tpl, ev.ID); err != nil {
			t.Fatal(err)
		}
	}
}

// sync runs Rollover rounds until nothing is left to publish.
func (v *vault) sync(t testing.TB, a acct, w *Wallet) {
	t.Helper()
	for range 5 {
		plan, err := w.Rollover()
		if err != nil {
			t.Fatal(err)
		}
		if len(plan.Events) == 0 {
			return
		}
		v.publishPlan(t, a, w, plan)
	}
	t.Fatal("rollover never settled")
}

// input is what the app reads and decrypts at login.
func (v *vault) input(t testing.TB, a acct) RestoreInput {
	t.Helper()
	in := RestoreInput{Account: a.pk}
	for _, e := range v.live() {
		if e.PubKey != a.pk {
			continue
		}
		switch e.Kind {
		case KindWallet:
			oe := a.open(t, e)
			in.Wallet = &oe
		case KindToken:
			in.Tokens = append(in.Tokens, a.open(t, e))
		case KindQuote:
			in.Quotes = append(in.Quotes, a.open(t, e))
		case KindDeletion:
			in.Deletions = append(in.Deletions, e)
		}
	}
	return in
}

func restore(t testing.TB, w *Wallet, v *vault, a acct) RestoreReport {
	t.Helper()
	rep, err := w.Restore(ctx, v.input(t, a))
	if err != nil {
		t.Fatal(err)
	}
	return rep
}

func wantReserved(t testing.TB, w *Wallet, sats uint64) {
	t.Helper()
	if b := w.Balance(); b.Reserved != sats {
		t.Fatalf("reserved %d, want %d", b.Reserved, sats)
	}
}
