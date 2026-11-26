package wallet

import (
	"errors"
	"testing"

	"github.com/elnosh/gonuts/cashu"
)

func walletEvents(plan RolloverPlan) int {
	n := 0
	for _, e := range plan.Events {
		if e.Kind == KindWallet {
			n++
		}
	}
	return n
}

// Tron must-fix 3: a device with its own key meets the Vault's different
// key. It must never publish its 17375 over the Vault's one.
func TestKeyConflictNeverOverwritesVaultKey(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	phone := openWallet(t, &MemStore{})
	if err := phone.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, phone, m, 10)
	v.sync(t, a, phone)
	phoneKey := phone.WalletPubkey()

	mac := openWallet(t, &MemStore{})
	if err := mac.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, mac, m, 5)
	if _, err := mac.Restore(ctx, v.input(t, a)); !errors.Is(err, ErrKeyConflict) {
		t.Fatalf("restore: %v", err)
	}
	plan, err := mac.Rollover()
	if err != nil {
		t.Fatal(err)
	}
	if walletEvents(plan) != 0 || plan.WalletHold == "" {
		t.Fatalf("17375 planned during a key conflict: %+v", plan)
	}
	v.sync(t, a, mac)
	fresh := openWallet(t, &MemStore{})
	restore(t, fresh, v, a)
	if fresh.WalletPubkey() != phoneKey {
		t.Fatalf("Vault key is now %s, want the phone's %s", fresh.WalletPubkey(), phoneKey)
	}
}

// Same rule for a 17375 we can't open: fail closed, never replace it.
func TestUnreadableWalletEventHoldsRollover(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	phone := openWallet(t, &MemStore{})
	if err := phone.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, phone, m, 10)
	v.sync(t, a, phone)
	in := v.input(t, a)
	in.Wallet.Plaintext = "not json"
	mac := openWallet(t, &MemStore{})
	if err := mac.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	if _, err := mac.Restore(ctx, in); err == nil {
		t.Fatal("unreadable 17375 restored")
	}
	plan, err := mac.Rollover()
	if err != nil {
		t.Fatal(err)
	}
	if walletEvents(plan) != 0 || plan.WalletHold == "" {
		t.Fatalf("17375 planned over an unreadable one: %+v", plan)
	}
	// A clean read of the same key lifts the hold.
	restore(t, phone, v, a)
	if p, _ := phone.Rollover(); p.WalletHold != "" {
		t.Fatalf("hold on a clean wallet: %+v", p)
	}
}

// Tron must-fix 4: a stuck op at a mint must not freeze that mint's backup.
// The 7375 keeps the proofs plus the op's inputs.
func TestStuckOpMintStillBackedUp(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	w := openWallet(t, &MemStore{})
	if err := w.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, w, m, 64)
	v.sync(t, a, w)
	// An op that never reached the mint and can't finish: its inputs are
	// out of the balance but still unspent.
	var in cashu.Proofs
	if err := w.commit(func(s *State) error {
		in = cashu.Proofs{s.Mints[m.URL()].Proofs[0]}
		s.takeProofs(m.URL(), in)
		s.Ops = append(s.Ops, Op{ID: "stuck-op", Kind: OpSwap, Mint: m.URL(), Inputs: in,
			Stuck: "test: mint unreachable", Created: 1})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	fund(t, w, m, 50)
	plan, err := w.Rollover()
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Busy) != 1 || len(plan.Events) == 0 {
		t.Fatalf("busy mint not backed up: %+v", plan)
	}
	v.sync(t, a, w)
	other := openWallet(t, &MemStore{})
	restore(t, other, v, a)
	if b := other.Balance(); b.Total != 114 {
		t.Fatalf("other device restored %d of 114", b.Total)
	}
}
