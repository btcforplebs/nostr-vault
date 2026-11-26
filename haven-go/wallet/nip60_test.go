package wallet

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// newSyncedWallet is a funded wallet with its key, published to v.
func newSyncedWallet(t *testing.T, m *testMint, v *vault, a acct, sats uint64) *Wallet {
	t.Helper()
	w := openWallet(t, &MemStore{})
	if err := w.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, w, m, sats)
	v.sync(t, a, w)
	return w
}

func TestWalletEventRoundTrip(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	phone := newSyncedWallet(t, m, v, a, 0)
	if err := phone.CreateWalletKey(); !errors.Is(err, ErrKeyConflict) {
		t.Fatalf("second key: %v", err)
	}
	if v.count(KindWallet) != 1 {
		t.Fatalf("%d wallet events", v.count(KindWallet))
	}
	// The key is in the encrypted content only, never in public tags.
	for _, e := range v.live() {
		if strings.Contains(e.Content, phone.state.WalletKey) || strings.Contains(fmt.Sprint(e.Tags), phone.state.WalletKey) {
			t.Fatal("wallet key visible in the event")
		}
	}

	mac := openWallet(t, &MemStore{})
	rep := restore(t, mac, v, a)
	if !rep.WalletFound || mac.WalletPubkey() != phone.WalletPubkey() || len(mac.Mints()) != 1 {
		t.Fatalf("restore %+v pub %q", rep, mac.WalletPubkey())
	}
	if plan, _ := mac.Rollover(); len(plan.Events) != 0 {
		t.Fatalf("restored wallet wants to republish: %+v", plan.Events)
	}

	// A device with its own different key never takes another one.
	other := openWallet(t, &MemStore{})
	if err := other.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	before := other.WalletPubkey()
	if _, err := other.Restore(ctx, v.input(t, a)); !errors.Is(err, ErrKeyConflict) {
		t.Fatalf("conflict: %v", err)
	}
	if other.WalletPubkey() != before {
		t.Fatal("key replaced")
	}

	// A 17375 we can't read is "can't be opened", and changes nothing.
	in := v.input(t, a)
	in.Wallet.Plaintext = "not json"
	fresh := openWallet(t, &MemStore{})
	if _, err := fresh.Restore(ctx, in); err == nil || !strings.Contains(err.Error(), "can't be opened") {
		t.Fatalf("bad 17375: %v", err)
	}
	if fresh.HasWalletKey() || len(fresh.Mints()) != 0 {
		t.Fatal("bad 17375 changed the wallet")
	}
}

func TestRolloverSendAndRestore(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	w := newSyncedWallet(t, m, v, a, 100)
	if v.count(KindToken) != 1 {
		t.Fatalf("%d token events", v.count(KindToken))
	}
	first := v.input(t, a).Tokens[0].Event.ID

	if _, err := w.Send(ctx, m.URL(), 30, "", "token"); err != nil {
		t.Fatal(err)
	}
	plan, err := w.Rollover()
	if err != nil {
		t.Fatal(err)
	}
	// Round 1: the new balance 7375 (del: the old one) and the exported set.
	// No kind-5 yet: the old one is deleted only once its replacement is in.
	var kinds []int
	for _, e := range plan.Events {
		kinds = append(kinds, e.Kind)
		if e.Kind == KindDeletion {
			t.Fatal("kind-5 before the replacement was committed")
		}
	}
	if len(plan.Events) != 2 {
		t.Fatalf("plan kinds %v", kinds)
	}
	var sawDel, sawExported bool
	for _, e := range plan.Events {
		var c TokenContent
		json.Unmarshal([]byte(e.Content), &c)
		if len(c.Del) == 1 && c.Del[0] == first {
			sawDel = true
		}
		if c.ExportedAt > 0 && c.Proofs.Amount() == 30 {
			sawExported = true
		}
	}
	if !sawDel || !sawExported {
		t.Fatalf("del %v exported %v", sawDel, sawExported)
	}
	v.publishPlan(t, a, w, plan)
	plan, _ = w.Rollover()
	if len(plan.Events) != 1 || plan.Events[0].Kind != KindDeletion || plan.Events[0].Tags[0][1] != first ||
		plan.Events[0].Tags[len(plan.Events[0].Tags)-1][1] != "7375" {
		t.Fatalf("round 2 %+v", plan.Events)
	}
	v.publishPlan(t, a, w, plan)
	if plan, _ = w.Rollover(); len(plan.Events) != 0 {
		t.Fatalf("not settled: %+v", plan.Events)
	}

	// A new device sees 70 to spend and 30 waiting to be claimed.
	mac := openWallet(t, &MemStore{})
	restore(t, mac, v, a)
	wantBalance(t, mac, 70)
	wantReserved(t, mac, 30)
	// Restoring again (same device) adds nothing twice.
	restore(t, mac, v, a)
	restore(t, w, v, a)
	wantBalance(t, mac, 70)
	wantBalance(t, w, 70)
	wantReserved(t, w, 30)
	if plan, _ := w.Rollover(); len(plan.Events) != 0 {
		t.Fatalf("restore on the same device made work: %+v", plan.Events)
	}
}

func TestRolloverIgnoresDeletedAndReplaced(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	w := newSyncedWallet(t, m, v, a, 64)
	if _, err := w.Send(ctx, m.URL(), 64, "", ""); err != nil {
		t.Fatal(err)
	}
	w.Reclaim(ctx, w.ReservedSets()[0].ID)
	// Publish only the first round (replacement in, old still there): the
	// del field alone must keep a reader from counting the old proofs.
	plan, _ := w.Rollover()
	v.publishPlan(t, a, w, plan)
	in := RestoreInput{Account: a.pk}
	for _, e := range v.events { // every event, deletions ignored by the relay
		if e.Kind == KindToken {
			in.Tokens = append(in.Tokens, a.open(t, e))
		}
	}
	mac := openWallet(t, &MemStore{})
	rep, err := mac.Restore(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	wantBalance(t, mac, 64)
	if rep.Deleted == 0 {
		t.Fatalf("replaced event not skipped: %+v", rep)
	}
}

func TestRolloverSkipsMintWithUnfinishedOp(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	w := newSyncedWallet(t, m, v, a, 64)
	w.hook = func(step string) error {
		if step == "swap:journaled" {
			return errCrash
		}
		return nil
	}
	if _, err := w.Send(ctx, m.URL(), 10, "", ""); !errors.Is(err, errCrash) {
		t.Fatal(err)
	}
	w.hook = nil
	plan, _ := w.Rollover()
	if len(plan.Events) != 0 || len(plan.Busy) != 1 {
		t.Fatalf("busy mint rolled over: %+v", plan)
	}
	// The Vault still lists the op's inputs, so a restore elsewhere keeps them.
	mac := openWallet(t, &MemStore{})
	restore(t, mac, v, a)
	wantBalance(t, mac, 64)
	// And a restore on this device does not put the inputs back.
	restore(t, w, v, a)
	if b := w.Balance(); b.Total != 0 || b.InFlight != 64 {
		t.Fatalf("restore put journaled inputs back: %+v", b)
	}
	w.Recover(ctx)
	v.sync(t, a, w)
	wantBalance(t, w, 54)
	other := openWallet(t, &MemStore{})
	restore(t, other, v, a)
	wantBalance(t, other, 54)
}

func TestTwoDevicesSpendSameRestoredProofs(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	seed := newSyncedWallet(t, m, v, a, 64)
	_ = seed
	phone := openWallet(t, &MemStore{})
	mac := openWallet(t, &MemStore{})
	restore(t, phone, v, a)
	restore(t, mac, v, a)
	wantBalance(t, phone, 64)
	wantBalance(t, mac, 64)

	// Both spend the same 64 proof. The mint takes the first only.
	if _, err := phone.Send(ctx, m.URL(), 40, "", ""); err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, phone)
	if _, err := mac.Send(ctx, m.URL(), 40, "", ""); !errors.Is(err, ErrAlreadySpent) {
		t.Fatalf("second spend: %v", err)
	}
	wantBalance(t, mac, 0)

	// The losing device's rollover must not delete what it never saw.
	plan, _ := mac.Rollover()
	seen := map[string]bool{}
	for _, oe := range v.input(t, a).Tokens {
		seen[oe.Event.ID] = true
	}
	for _, e := range plan.Events {
		for _, id := range append(append([]string(nil), e.Meta.Deletes...), e.Meta.Replaces...) {
			if seen[id] {
				t.Fatalf("stale device deletes the winner's event %s", id)
			}
		}
	}
	v.publishPlan(t, a, mac, plan)

	// After re-reading, the mac has exactly what the phone has.
	restore(t, mac, v, a)
	wantBalance(t, mac, 24)
	wantReserved(t, mac, 40)
	fresh := openWallet(t, &MemStore{})
	restore(t, fresh, v, a)
	wantBalance(t, fresh, 24)
	wantReserved(t, fresh, 40)
	// Spending on the mac now works (it re-read and retried).
	if _, err := mac.Send(ctx, m.URL(), 8, "", ""); err != nil {
		t.Fatal(err)
	}
}

func TestTwoDevicesStaleRolloverMerges(t *testing.T) {
	// The phone spends while the mac, with a stale copy, receives new money
	// and publishes its own view. No sats are lost: Restore merges by secret
	// and checkstate drops what was spent.
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	newSyncedWallet(t, m, v, a, 64)
	phone := openWallet(t, &MemStore{})
	mac := openWallet(t, &MemStore{})
	restore(t, phone, v, a)
	restore(t, mac, v, a)

	if _, err := phone.Send(ctx, m.URL(), 64, "", "all of it"); err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, phone)

	gift := openWallet(t, &MemStore{})
	fund(t, gift, m, 16)
	r, err := gift.Send(ctx, m.URL(), 16, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mac.Receive(ctx, m.URL(), r.Proofs, nil, ""); err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, mac) // stale: still lists the 64 the phone spent

	for _, w := range []*Wallet{phone, mac, openWallet(t, &MemStore{})} {
		restore(t, w, v, a)
		wantBalance(t, w, 16)
		wantReserved(t, w, 64)
	}
	// Once both settle again, the Vault holds one balance 7375.
	v.sync(t, a, mac)
	v.sync(t, a, phone)
	restore(t, phone, v, a)
	v.sync(t, a, phone)
	balance := 0
	for _, oe := range v.input(t, a).Tokens {
		var c TokenContent
		json.Unmarshal([]byte(oe.Plaintext), &c)
		if c.ExportedAt == 0 {
			balance++
		}
	}
	if balance != 1 {
		t.Fatalf("%d balance 7375s left", balance)
	}
}

func TestQuoteEventRestoreAndClaim(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	phone := newSyncedWallet(t, m, v, a, 0)
	q, err := phone.RequestMint(ctx, m.URL(), 21)
	if err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, phone)
	if v.count(KindQuote) != 1 {
		t.Fatal("no 7374")
	}
	ev := v.input(t, a).Quotes[0]
	if ev.Plaintext != q.ID || strings.Contains(ev.Event.Content, q.ID) {
		t.Fatal("quote id must be in the encrypted content only")
	}

	mac := openWallet(t, &MemStore{})
	rep := restore(t, mac, v, a)
	if rep.Quotes != 1 || len(mac.MintQuotes()) != 1 || mac.MintQuotes()[0].Amount != 21 {
		t.Fatalf("quote not restored: %+v %+v", rep, mac.MintQuotes())
	}
	m.payMintQuote(q.ID)
	if got, err := mac.ClaimMint(ctx, q.ID); err != nil || got != 21 {
		t.Fatalf("claim %d %v", got, err)
	}
	v.sync(t, a, mac)
	if v.count(KindQuote) != 0 {
		t.Fatal("claimed quote's 7374 not deleted")
	}
	restore(t, phone, v, a)
	wantBalance(t, phone, 21)
}

func TestRestoreSkipsForeignAndBadEvents(t *testing.T) {
	m := newTestMint(t, 0)
	a, eve := newAcct(t), newAcct(t)
	v := &vault{}
	w := newSyncedWallet(t, m, v, a, 32)
	in := v.input(t, a)
	// Eve's token event, and one of ours with its content changed.
	forged := eve.sign(t, Template{Kind: KindToken, Content: in.Tokens[0].Plaintext, Encrypt: true})
	in.Tokens = append(in.Tokens, eve.open(t, forged))
	tampered := in.Tokens[0]
	tampered.Event.Tags = nostr.Tags{{"x"}}
	in.Tokens = append(in.Tokens, tampered)
	// Eve's kind-5 for our event is ignored.
	in.Deletions = append(in.Deletions, eve.sign(t, Template{Kind: KindDeletion, Tags: nostr.Tags{{"e", in.Tokens[0].Event.ID}}}))
	mac := openWallet(t, &MemStore{})
	rep, err := mac.Restore(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Bad) != 2 {
		t.Fatalf("bad %v", rep.Bad)
	}
	wantBalance(t, mac, 32)
	_ = w
}

func TestCommitPublishedChecksInput(t *testing.T) {
	w := openWallet(t, &MemStore{})
	if err := w.CommitPublished(Template{Kind: KindToken, Meta: &TemplateMeta{}}, "abc"); err == nil {
		t.Fatal("short id accepted")
	}
	if err := w.CommitPublished(Template{Kind: KindToken}, strings.Repeat("a", 64)); err == nil {
		t.Fatal("template without meta accepted")
	}
}

func TestBolt11Sats(t *testing.T) {
	for inv, want := range map[string]uint64{
		"lnbc2500u1pvjluez":  250_000,
		"lnbc20m1pvjluez":    2_000_000,
		"lnbc1500n1abc":      150,
		"lnbc10p1abc":        0, // 1 msat: not whole sats
		"lnbc10000p1abc":     1,
		"lnbc1pvjluez":       0, // no amount
		"lntb100n1x":         10,
		"LIGHTNING:LNBC5U1X": 500,
		"lnbcpaymemq1":       0,
	} {
		if got := bolt11Sats(inv); got != want {
			t.Errorf("%s: %d, want %d", inv, got, want)
		}
	}
}
