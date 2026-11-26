package wallet

import (
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/elnosh/gonuts/cashu"
)

// Tron #2570 must-fix 1: a second device with a stale copy must not keep
// exported proofs spendable, nor let its Rollover delete the export.
func TestStaleDeviceRestoreHoldsExport(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	newSyncedWallet(t, m, v, a, 64)
	phone := openWallet(t, &MemStore{})
	mac := openWallet(t, &MemStore{})
	restore(t, phone, v, a)
	restore(t, mac, v, a)
	wantBalance(t, mac, 64)

	exp, err := phone.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, phone)

	if rep := restore(t, mac, v, a); rep.Added != 0 {
		t.Fatalf("moved proofs counted as new money: %+v", rep)
	}
	wantBalance(t, mac, 0)
	wantReserved(t, mac, 64)
	if _, err := mac.Send(ctx, m.URL(), 64, "", ""); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("mac spends the exported proofs: %v", err)
	}
	ws := mac.WaitingTokens()
	if len(ws) != 1 || ws[0].Amount != 64 {
		t.Fatalf("mac waiting %+v", ws)
	}
	v.sync(t, a, mac)
	fresh := openWallet(t, &MemStore{})
	restore(t, fresh, v, a)
	wantBalance(t, fresh, 0)
	wantReserved(t, fresh, 64)
	if ws := fresh.WaitingTokens(); len(ws) != 1 || ws[0].Token != exp.Token {
		t.Fatalf("fresh waiting %+v", ws)
	}
}

// Tron #2570 must-fix 2: a P2PK proof locked to us stays in the balance;
// the export takes only the unlocked proofs and can be taken back.
func TestExportSkipsP2PKProofs(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	alice := newSyncedWallet(t, m, v, a, 40)
	alice.mu.Lock()
	lock := alice.myLockLocked()
	alice.mu.Unlock()
	if lock == "" {
		t.Fatal("no wallet key")
	}
	if err := alice.commit(func(s *State) error {
		p := s.Mints[m.URL()].Proofs[0]
		p.Secret = fmt.Sprintf(`["P2PK",{"nonce":"%064x","data":"%s"}]`, 7, lock)
		p.DLEQ = nil
		s.addProofs(m.URL(), cashu.Proofs{p})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	locked := alice.Balance().Total - 40

	exp, err := alice.ExportToken(m.URL())
	if err != nil || exp.Amount != 40 {
		t.Fatalf("export %+v %v", exp, err)
	}
	wantBalance(t, alice, locked)
	if again, err := alice.TokenFor(exp.Reserved); err != nil || again.Token != exp.Token {
		t.Fatalf("token for %v", err)
	}
	if res, err := alice.TakeBack(ctx, exp.Reserved); err != nil || res.Returned != 40 {
		t.Fatalf("take back %+v %v", res, err)
	}
	wantReserved(t, alice, 0)

	// Only the locked proof left: nothing to export, and nothing moved.
	if err := alice.commit(func(s *State) error {
		s.Mints[m.URL()].Proofs = unlockedProofsInverse(s.Mints[m.URL()].Proofs)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := alice.ExportToken(m.URL()); !errors.Is(err, ErrNothingToExport) {
		t.Fatalf("export of locked only: %v", err)
	}
	wantBalance(t, alice, locked)
	wantReserved(t, alice, 0)
}

func unlockedProofsInverse(ps cashu.Proofs) cashu.Proofs {
	keep := map[string]bool{}
	for _, p := range unlockedProofs(ps) {
		keep[p.Secret] = true
	}
	var out cashu.Proofs
	for _, p := range ps {
		if !keep[p.Secret] {
			out = append(out, p)
		}
	}
	return out
}

// Tron #2570 should-fix 3: close + reopen of a path gets the same engine.
func TestBridgeReopenSameEngine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.json")
	h1 := bopen(t, path)
	w1, err := cashuWalletFor(h1)
	if err != nil {
		t.Fatal(err)
	}
	BridgeClose(h1)
	h2 := bopen(t, path)
	defer BridgeClose(h2)
	w2, err := cashuWalletFor(h2)
	if err != nil || w1 != w2 {
		t.Fatalf("reopen made a second engine (%v)", err)
	}
}

// Tron #2570 should-fix 4: a stuck reclaim of the set blocks another.
func TestTakeBackRefusedWhileReclaimStuck(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 50)
	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	if err := alice.commit(func(s *State) error {
		s.Ops = append(s.Ops, Op{ID: "stuck", Kind: OpReclaim, Mint: m.URL(), Reserved: exp.Reserved, Stuck: "bad reply"})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if res, err := alice.TakeBack(ctx, exp.Reserved); !errors.Is(err, ErrBusy) || res.Claim != nil {
		t.Fatalf("take back with stuck reclaim %+v %v", res, err)
	}
	if _, err := alice.Reclaim(ctx, exp.Reserved); !errors.Is(err, ErrBusy) {
		t.Fatalf("reclaim with stuck reclaim %v", err)
	}
	wantReserved(t, alice, 50)
}

// Tron #2570 low 1: a claim during the retry is counted, and Done is set
// once the rest came back.
func TestTakeBackClaimDuringRetry(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 100) // 64 + 32 + 4
	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	_, proofs := decodeExport(t, exp.Token)
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if _, err := bob.Receive(ctx, m.URL(), pick(proofs, 32), nil, ""); err != nil {
		t.Fatal(err)
	}
	tries := 0
	alice.hook = func(s string) error {
		if s == "swap:journaled" {
			if tries++; tries == 2 {
				if _, err := bob.Receive(ctx, m.URL(), pick(proofs, 4), nil, ""); err != nil {
					return err
				}
			}
		}
		return nil
	}
	res, err := alice.TakeBack(ctx, exp.Reserved)
	alice.hook = nil
	if err != nil || res.Returned != 64 || res.Claim == nil || res.Claim.Amount != 36 || !res.Claim.Done {
		t.Fatalf("take back %+v claim %+v %v", res, res.Claim, err)
	}
	wantBalance(t, alice, 64)
	wantReserved(t, alice, 0)
	wantNoOps(t, alice)
}

// Tron #2570 low 2: our own waiting token pasted back is refused.
func TestReceiveOwnTokenRefused(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 30)
	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	_, proofs := decodeExport(t, exp.Token)
	if _, err := alice.Receive(ctx, m.URL(), proofs, nil, ""); !errors.Is(err, ErrOwnProofs) {
		t.Fatalf("receive own token: %v", err)
	}
	wantBalance(t, alice, 0)
	wantReserved(t, alice, 30)
}
