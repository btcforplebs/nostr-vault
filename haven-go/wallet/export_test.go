package wallet

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/elnosh/gonuts/cashu"
)

// decodeExport is the other wallet reading our token (Zeus/Minibits do the
// same NUT-00 decode).
func decodeExport(t *testing.T, tok string) (string, cashu.Proofs) {
	t.Helper()
	if !strings.HasPrefix(tok, "cashuB") {
		t.Fatalf("token %q is not cashuB", tok[:min(len(tok), 10)])
	}
	d, err := cashu.DecodeToken(tok)
	if err != nil {
		t.Fatal(err)
	}
	return d.Mint(), d.Proofs()
}

func pick(ps cashu.Proofs, amount uint64) cashu.Proofs {
	for _, p := range ps {
		if p.Amount == amount {
			return cashu.Proofs{p}
		}
	}
	return nil
}

func TestExportTokenHeldBackThenClaimed(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 100)
	calls := m.callCount("/v1/swap")

	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	if exp.Amount != 100 || exp.Fee != 0 || exp.Mint != m.URL() {
		t.Fatalf("export %+v", exp)
	}
	if m.callCount("/v1/swap") != calls {
		t.Fatal("export called the mint")
	}
	// Held back: not spendable, shown as waiting on its mint.
	wantBalance(t, alice, 0)
	if b := alice.Balance(); b.Reserved != 100 || b.ReservedPerMint[m.URL()] != 100 {
		t.Fatalf("balance %+v", b)
	}
	if _, err := alice.Send(ctx, m.URL(), 1, "", ""); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("spend of exported proofs: %v", err)
	}
	if _, err := alice.ExportToken(m.URL()); !errors.Is(err, ErrNothingToExport) {
		t.Fatalf("second export: %v", err)
	}
	// The same token every time the card reopens.
	again, err := alice.TokenFor(exp.Reserved)
	if err != nil || again.Token != exp.Token {
		t.Fatalf("token changed: %v", err)
	}
	if ws := alice.WaitingTokens(); len(ws) != 1 || ws[0].Token != exp.Token {
		t.Fatalf("waiting %+v", ws)
	}

	mint, proofs := decodeExport(t, exp.Token)
	if mint != m.URL() || proofs.Amount() != 100 {
		t.Fatalf("decoded %s %d", mint, proofs.Amount())
	}
	for _, p := range proofs {
		if p.DLEQ == nil {
			t.Fatal("token lost its DLEQ")
		}
	}
	// Nothing claimed yet: checkstate keeps it waiting.
	rep, err := alice.CheckState(ctx, m.URL())
	if err != nil || len(rep.Claims) != 0 || rep.Claimed != 0 {
		t.Fatalf("checkstate before claim %+v %v", rep, err)
	}

	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if got, err := bob.Receive(ctx, m.URL(), proofs, nil, ""); err != nil || got != 100 {
		t.Fatalf("bob claim %d %v", got, err)
	}
	rep, err = alice.CheckState(ctx, m.URL())
	if err != nil || len(rep.Claims) != 1 {
		t.Fatalf("checkstate after claim %+v %v", rep, err)
	}
	c := rep.Claims[0]
	if c.Amount != 100 || !c.Done || c.Reserved != exp.Reserved || c.History.In || c.History.Amount != 100 {
		t.Fatalf("claim %+v", c)
	}
	if _, err := alice.HistoryTemplate(c.History); err != nil {
		t.Fatal(err)
	}
	wantReserved(t, alice, 0)
	if rep, _ := alice.CheckState(ctx, m.URL()); len(rep.Claims) != 0 {
		t.Fatalf("claim reported twice: %+v", rep)
	}
}

func TestExportPartialClaimRolloverAndTakeBack(t *testing.T) {
	m := newTestMint(t, 0)
	a := newAcct(t)
	v := &vault{}
	alice := newSyncedWallet(t, m, v, a, 100) // 64 + 32 + 4
	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	v.sync(t, a, alice)
	exported := func() []TokenContent {
		var out []TokenContent
		for _, oe := range v.input(t, a).Tokens {
			var c TokenContent
			json.Unmarshal([]byte(oe.Plaintext), &c)
			if c.ExportedAt > 0 {
				out = append(out, c)
			}
		}
		return out
	}
	if ex := exported(); len(ex) != 1 || ex[0].Proofs.Amount() != 100 {
		t.Fatalf("vault exported sets %+v", ex)
	}
	oldID := v.input(t, a).Tokens[0].Event.ID

	// Bob claims only the 64.
	_, proofs := decodeExport(t, exp.Token)
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if got, err := bob.Receive(ctx, m.URL(), pick(proofs, 64), nil, ""); err != nil || got != 64 {
		t.Fatalf("bob partial claim %d %v", got, err)
	}
	rep, err := alice.CheckState(ctx, m.URL())
	if err != nil || len(rep.Claims) != 1 {
		t.Fatalf("checkstate %+v %v", rep, err)
	}
	c := rep.Claims[0]
	if c.Amount != 64 || c.Done || len(c.History.Destroyed) != 1 || c.History.Destroyed[0] != oldID {
		t.Fatalf("partial claim %+v", c)
	}
	wantReserved(t, alice, 36)
	wantBalance(t, alice, 0)

	// The rollover re-publishes only the 36 still waiting, then deletes the old.
	v.sync(t, a, alice)
	if ex := exported(); len(ex) != 1 || ex[0].Proofs.Amount() != 36 {
		t.Fatalf("after partial claim, vault exported sets %+v", ex)
	}
	// Another device sees the same: 36 waiting, the same token for them.
	mac := openWallet(t, &MemStore{})
	restore(t, mac, v, a)
	wantBalance(t, mac, 0)
	wantReserved(t, mac, 36)
	ws := mac.WaitingTokens()
	if len(ws) != 1 || ws[0].Amount != 36 {
		t.Fatalf("mac waiting %+v", ws)
	}

	// Take back the rest: the shown token is now worthless.
	res, err := alice.TakeBack(ctx, exp.Reserved)
	if err != nil || res.Returned != 36 || res.Claim != nil {
		t.Fatalf("take back %+v %v", res, err)
	}
	wantBalance(t, alice, 36)
	wantReserved(t, alice, 0)
	if _, err := bob.Receive(ctx, m.URL(), proofs, nil, ""); !errors.Is(err, ErrAlreadySpent) {
		t.Fatalf("token still good after take back: %v", err)
	}
	v.sync(t, a, alice)
	if ex := exported(); len(ex) != 0 {
		t.Fatalf("taken-back set still in vault %+v", ex)
	}
	// The other device's checkstate drops its copy of the set.
	if rep, err := mac.CheckState(ctx, m.URL()); err != nil || rep.Claimed != 36 {
		t.Fatalf("mac checkstate %+v %v", rep, err)
	}
	restore(t, mac, v, a)
	wantBalance(t, mac, 36)
	wantReserved(t, mac, 0)
}

func TestTakeBackAfterPartialClaimNoCheck(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 100)
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
	// The mint refuses the whole swap (one input spent); TakeBack records
	// the claimed 32 and swaps back the other 68; nothing is left waiting.
	res, err := alice.TakeBack(ctx, exp.Reserved)
	if err != nil || res.Returned != 68 || res.Claim == nil || res.Claim.Amount != 32 || !res.Claim.Done {
		t.Fatalf("take back %+v %v", res, err)
	}
	wantBalance(t, alice, 68)
	wantReserved(t, alice, 0)
	wantNoOps(t, alice)
}

func TestTakeBackFullyClaimed(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 50)
	exp, _ := alice.ExportToken(m.URL())
	_, proofs := decodeExport(t, exp.Token)
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if _, err := bob.Receive(ctx, m.URL(), proofs, nil, ""); err != nil {
		t.Fatal(err)
	}
	res, err := alice.TakeBack(ctx, exp.Reserved)
	if !errors.Is(err, ErrAlreadySpent) || res.Claim == nil || !res.Claim.Done || res.Claim.Amount != 50 {
		t.Fatalf("take back of claimed token %+v %v", res, err)
	}
	wantBalance(t, alice, 0)
	wantReserved(t, alice, 0)
	wantNoOps(t, alice)
}

func TestExportPendingKeepsWaiting(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 64)
	exp, _ := alice.ExportToken(m.URL())
	_, proofs := decodeExport(t, exp.Token)
	y, err := proofY(proofs[0].Secret)
	if err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	m.pending[y] = true // the other wallet's melt holds it
	m.mu.Unlock()
	rep, err := alice.CheckState(ctx, m.URL())
	if err != nil || len(rep.Claims) != 0 {
		t.Fatalf("checkstate %+v %v", rep, err)
	}
	wantReserved(t, alice, 64)
	// Take back can't settle a pending proof: the set stays waiting.
	if _, err := alice.TakeBack(ctx, exp.Reserved); err == nil {
		t.Fatal("take back of a pending proof worked")
	} else if !errors.Is(err, ErrPending) {
		t.Fatalf("pending take back: %v", err)
	}
	alice.Recover(ctx)
	if b := alice.Balance(); b.Reserved+b.Total+b.InFlight != 64 {
		t.Fatalf("sats lost while pending: %+v", b)
	}
	m.mu.Lock()
	delete(m.pending, y)
	m.mu.Unlock()
	// Once the mint lets go, Recover settles the journaled take back (or
	// undoes it, and a second tap finishes it).
	alice.Recover(ctx)
	if len(alice.ReservedSets()) > 0 {
		if res, err := alice.TakeBack(ctx, exp.Reserved); err != nil || res.Returned != 64 {
			t.Fatalf("take back after pending cleared %+v %v", res, err)
		}
	}
	wantBalance(t, alice, 64)
	wantNoOps(t, alice)
}

func TestExportRefusals(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	if _, err := alice.ExportToken(m.URL()); !errors.Is(err, ErrUnknownMint) {
		t.Fatalf("unknown mint: %v", err)
	}
	fund(t, alice, m, 64)
	// A nutzap-style locked set is not a token.
	if err := alice.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	other := newAcct(t)
	sent, err := alice.Send(ctx, m.URL(), 8, other.pk, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := alice.TokenFor(sent.ID); !errors.Is(err, ErrNotAToken) {
		t.Fatalf("token for a locked set: %v", err)
	}
	if _, err := alice.TakeBack(ctx, sent.ID); !errors.Is(err, ErrNotAToken) {
		t.Fatalf("take back of a locked set: %v", err)
	}
	// An unfinished op at the mint blocks export.
	alice.hook = func(step string) error {
		if step == "swap:journaled" {
			return errCrash
		}
		return nil
	}
	if _, err := alice.Send(ctx, m.URL(), 4, "", ""); !errors.Is(err, errCrash) {
		t.Fatal(err)
	}
	alice.hook = nil
	if _, err := alice.ExportToken(m.URL()); !errors.Is(err, ErrBusy) {
		t.Fatalf("export with unfinished op: %v", err)
	}
	alice.Recover(ctx)
	have := alice.Balance().Total
	exp, err := alice.ExportToken(m.URL())
	if err != nil || exp.Amount != have || have == 0 {
		t.Fatalf("export after recover %+v %v", exp, err)
	}
}

func TestExportFeeShown(t *testing.T) {
	m := newTestMint(t, 1000) // 1 sat per proof
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 7) // 4 + 2 + 1
	exp, err := alice.ExportToken(m.URL())
	if err != nil {
		t.Fatal(err)
	}
	if exp.Fee != 3 {
		t.Fatalf("fee %d, want 3", exp.Fee)
	}
	_, proofs := decodeExport(t, exp.Token)
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if got, err := bob.Receive(ctx, m.URL(), proofs, nil, ""); err != nil || got != 4 {
		t.Fatalf("bob got %d %v", got, err)
	}
}
