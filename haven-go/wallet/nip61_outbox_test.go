package wallet

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func zapReq(ba acct, info NutzapInfo, sats uint64) NutzapRequest {
	return NutzapRequest{Recipient: ba.pk, Info: info, Amount: sats, Comment: "great note",
		EventID: strings.Repeat("e", 64), EventKind: 1}
}

// Tron must-fix 1: the mint signs the nutzap without DLEQ. No 9321 can be
// built, but the sats carry a refund to our wallet key and come back after
// the locktime; before it neither we nor the mint let them back.
func TestNutzapNoDLEQRefundsAfterLocktime(t *testing.T) {
	m := newTestMint(t, 0)
	alice, _, _, ba, info := nutzapSetup(t, m)
	m.noDLEQ = true
	_, r, err := alice.SendNutzap(ctx, zapReq(ba, info, 21))
	if !errors.Is(err, ErrNutzapNoDLEQ) {
		t.Fatalf("send: %v", err)
	}
	wantBalance(t, alice, 79)
	start := time.Now()
	if r.ID == "" || r.RefundAfter < start.Unix()+NutzapRefundAfter-60 {
		t.Fatalf("reserved %+v", r)
	}
	if len(alice.UnsentNutzaps()) != 0 {
		t.Fatal("a nutzap with no DLEQ can't be rebuilt; it must not be listed as unsent")
	}
	if _, err := alice.Reclaim(ctx, r.ID); !errors.Is(err, ErrRefundNotYet) {
		t.Fatalf("reclaim before locktime: %v", err)
	}
	// Positive control: our clock says the locktime passed but the mint's
	// does not, so the mint refuses the refund signature and the set stays.
	later := start.Add(time.Duration(NutzapRefundAfter+60) * time.Second)
	alice.now = func() time.Time { return later }
	if _, err := alice.Reclaim(ctx, r.ID); err == nil {
		t.Fatal("mint took a refund signature before the locktime")
	}
	wantReserved(t, alice, 21)
	m.clock = later.Unix()
	got, err := alice.Reclaim(ctx, r.ID)
	if err != nil || got != 21 {
		t.Fatalf("reclaim after locktime: %d %v", got, err)
	}
	wantBalance(t, alice, 100)
	wantReserved(t, alice, 0)
}

// Tron must-fix 2: the app dies after SendNutzap and before the publish.
// The reopened wallet lists the unsent nutzap and rebuilds a 9321 bob can
// verify and redeem; once committed it is no longer listed.
func TestNutzapRebuiltAfterKill(t *testing.T) {
	m := newTestMint(t, 0)
	aa, ba := newAcct(t), newAcct(t)
	store := &MemStore{}
	alice := openWallet(t, store)
	fund(t, alice, m, 100)
	if err := alice.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	_, bob, _, _, info := nutzapSetup(t, m)
	if _, _, err := alice.SendNutzap(ctx, zapReq(ba, info, 21)); err != nil {
		t.Fatal(err)
	}
	// Killed here: the template is lost.
	alice = openWallet(t, store)
	un := alice.UnsentNutzaps()
	if len(un) != 1 || un[0].Nutzap == nil || un[0].Nutzap.Recipient != ba.pk {
		t.Fatalf("unsent %+v", un)
	}
	tpl, err := alice.NutzapTemplateFor(un[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if tpl.Where != WhereRecipient || len(tpl.Relays) != 1 || tpl.Content != "great note" {
		t.Fatalf("rebuilt %+v", tpl)
	}
	ev := aa.sign(t, tpl)
	nz, err := bob.VerifyNutzap(ctx, ev, ba.pk, info.Mints)
	if err != nil || nz.Amount != 21 || nz.Shared {
		t.Fatalf("verify rebuilt: %+v %v", nz, err)
	}
	if err := alice.CommitPublished(tpl, ev.ID); err != nil {
		t.Fatal(err)
	}
	if len(alice.UnsentNutzaps()) != 0 {
		t.Fatal("still unsent after commit")
	}
	if _, err := alice.NutzapTemplateFor(un[0].ID); !errors.Is(err, ErrNoNutzap) {
		t.Fatalf("rebuild after commit: %v", err)
	}
	if got, _, err := bob.RedeemNutzap(ctx, nz, ""); err != nil || got != 21 {
		t.Fatalf("redeem %d %v", got, err)
	}
}

// A kill between the swap being journaled and applied: Recover finishes the
// swap and the Reserved set still carries the request.
func TestNutzapRequestSurvivesRecover(t *testing.T) {
	m := newTestMint(t, 0)
	store := &MemStore{}
	alice := openWallet(t, store)
	fund(t, alice, m, 100)
	if err := alice.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	_, _, _, ba, info := nutzapSetup(t, m)
	alice.hook = func(s string) error {
		if s == "swap:answered" {
			return errCrash
		}
		return nil
	}
	if _, _, err := alice.SendNutzap(ctx, zapReq(ba, info, 21)); !errors.Is(err, errCrash) {
		t.Fatalf("crash: %v", err)
	}
	alice = openWallet(t, store)
	if rep := alice.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover %+v", rep)
	}
	un := alice.UnsentNutzaps()
	if len(un) != 1 || un[0].Nutzap == nil || un[0].RefundAfter == 0 {
		t.Fatalf("unsent after recover %+v", un)
	}
	if _, err := alice.NutzapTemplateFor(un[0].ID); err != nil {
		t.Fatal(err)
	}
}
