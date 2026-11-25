package wallet

import (
	"context"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/elnosh/gonuts/cashu"
)

var ctx = context.Background()

func openWallet(t testing.TB, store Store) *Wallet {
	t.Helper()
	w, err := Open(store)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// fund adds the mint to w and mints amount sats into it.
func fund(t testing.TB, w *Wallet, m *testMint, amount uint64) {
	t.Helper()
	if _, err := w.AddMint(ctx, m.URL()); err != nil {
		t.Fatal(err)
	}
	if amount == 0 {
		return
	}
	q, err := w.RequestMint(ctx, m.URL(), amount)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.ClaimMint(ctx, q.ID); !errors.Is(err, ErrNotPaid) {
		t.Fatalf("claim before pay: %v, want ErrNotPaid", err)
	}
	m.payMintQuote(q.ID)
	got, err := w.ClaimMint(ctx, q.ID)
	if err != nil || got != amount {
		t.Fatalf("claim: %d %v", got, err)
	}
}

func wantBalance(t testing.TB, w *Wallet, total uint64) {
	t.Helper()
	if b := w.Balance(); b.Total != total {
		t.Fatalf("balance %d, want %d (reserved %d, in flight %d)", b.Total, total, b.Reserved, b.InFlight)
	}
}

func wantNoOps(t testing.TB, w *Wallet) {
	t.Helper()
	if ops := w.Pending(); len(ops) != 0 {
		t.Fatalf("%d ops left: %+v", len(ops), ops)
	}
}

func TestMintSendReceiveCheckState(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 100)
	wantBalance(t, alice, 100)
	if len(alice.MintQuotes()) != 0 {
		t.Fatal("claimed quote still listed")
	}

	sent, err := alice.Send(ctx, m.URL(), 30, "", "for bob")
	if err != nil {
		t.Fatal(err)
	}
	if sent.Proofs.Amount() != 30 {
		t.Fatalf("sent %d", sent.Proofs.Amount())
	}
	wantBalance(t, alice, 70)
	if b := alice.Balance(); b.Reserved != 30 {
		t.Fatalf("reserved %d", b.Reserved)
	}

	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	got, err := bob.Receive(ctx, m.URL(), sent.Proofs, nil, "")
	if err != nil || got != 30 {
		t.Fatalf("receive %d %v", got, err)
	}
	wantBalance(t, bob, 30)
	// The same token twice: the mint refuses, nothing is credited.
	if _, err := bob.Receive(ctx, m.URL(), sent.Proofs, nil, ""); !errors.Is(err, ErrAlreadySpent) {
		t.Fatalf("second receive: %v", err)
	}
	wantBalance(t, bob, 30)
	wantNoOps(t, bob)

	rep, err := alice.CheckState(ctx, m.URL())
	if err != nil || rep.Claimed != 30 || rep.SpentDropped != 0 {
		t.Fatalf("checkstate %+v %v", rep, err)
	}
	if len(alice.ReservedSets()) != 0 {
		t.Fatal("claimed set still reserved")
	}
	wantBalance(t, alice, 70)
}

func TestP2PKNutzapNeedsKey(t *testing.T) {
	m := newTestMint(t, 0)
	alice := openWallet(t, &MemStore{})
	fund(t, alice, m, 64)
	key, _ := btcec.NewPrivateKey()
	xonly := key.PubKey().SerializeCompressed()[1:] // a 10019 pubkey is x-only
	sent, err := alice.Send(ctx, m.URL(), 21, hex.EncodeToString(xonly), "nutzap")
	if err != nil {
		t.Fatal(err)
	}
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	if _, err := bob.Receive(ctx, m.URL(), sent.Proofs, nil, ""); err == nil || !IsDefinite(err) {
		t.Fatalf("receive without key: %v", err)
	}
	other, _ := btcec.NewPrivateKey()
	if _, err := bob.Receive(ctx, m.URL(), sent.Proofs, other, ""); err == nil {
		t.Fatal("receive with wrong key worked")
	}
	wantNoOps(t, bob)
	got, err := bob.Receive(ctx, m.URL(), sent.Proofs, key, "")
	if err != nil || got != 21 {
		t.Fatalf("receive with key: %d %v", got, err)
	}
	// Alice can't reclaim proofs locked to Bob's key.
	if _, err := alice.Reclaim(ctx, sent.ID); err == nil {
		t.Fatal("reclaim of locked set worked")
	}
}

func TestReclaim(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 50)
	sent, err := w.Send(ctx, m.URL(), 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	got, err := w.Reclaim(ctx, sent.ID)
	if err != nil || got != 20 {
		t.Fatalf("reclaim %d %v", got, err)
	}
	wantBalance(t, w, 50)
	if len(w.ReservedSets()) != 0 {
		t.Fatal("reclaimed set still reserved")
	}
}

func TestMeltWithChange(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	q, err := w.QuoteMelt(ctx, m.URL(), m.invoice(40))
	if err != nil {
		t.Fatal(err)
	}
	if q.Amount != 40 || q.FeeReserve != 4 {
		t.Fatalf("quote %+v", q)
	}
	res, err := w.Melt(ctx, q)
	if err != nil {
		t.Fatal(err)
	}
	if res.Preimage == "" {
		t.Fatal("no preimage")
	}
	wantBalance(t, w, 100-40-1) // actual fee 1; unused reserve comes back
	wantNoOps(t, w)
	if _, err := w.Melt(ctx, q); err == nil {
		t.Fatal("paid quote paid again")
	}
	wantBalance(t, w, 59)
}

func TestMeltNotEnough(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 40)
	q, err := w.QuoteMelt(ctx, m.URL(), m.invoice(40))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Melt(ctx, q); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("melt over balance: %v", err)
	}
	wantBalance(t, w, 40)
	if m.callCount("/v1/melt/bolt11") != 0 {
		t.Fatal("mint was asked to melt")
	}
}

func TestMeltPendingThenPaid(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	m.meltPending = true
	q, _ := w.QuoteMelt(ctx, m.URL(), m.invoice(10))
	if _, err := w.Melt(ctx, q); !errors.Is(err, ErrPending) {
		t.Fatalf("pending melt: %v", err)
	}
	if _, err := w.Send(ctx, m.URL(), 1, "", ""); !errors.Is(err, ErrBusy) {
		t.Fatalf("send during pending melt: %v", err)
	}
	if rep := w.Recover(ctx); rep.Left != 1 {
		t.Fatalf("recover while pending: %+v", rep)
	}
	m.settleMelt(q.ID, true)
	if rep := w.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover after paid: %+v", rep)
	}
	wantBalance(t, w, 100-10-1)
	wantNoOps(t, w)
}

func TestMeltPendingThenFailed(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	m.meltPending = true
	q, _ := w.QuoteMelt(ctx, m.URL(), m.invoice(10))
	if _, err := w.Melt(ctx, q); !errors.Is(err, ErrPending) {
		t.Fatalf("pending melt: %v", err)
	}
	m.settleMelt(q.ID, false)
	// Recover sends the melt again (the first copy could still be in
	// flight); this time the payment fails at once, so the op is undone.
	m.meltPending, m.meltFail = false, true
	if rep := w.Recover(ctx); rep.Undone != 1 {
		t.Fatalf("recover after fail: %+v", rep)
	}
	wantBalance(t, w, 100)
	wantNoOps(t, w)
}

func TestInputFees(t *testing.T) {
	m := newTestMint(t, 400) // 0.4 sat per input
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100) // 64+32+4
	sent, err := w.Send(ctx, m.URL(), 10, "", "")
	if err != nil {
		t.Fatal(err)
	}
	// One 64 input: fee ceil(0.4)=1. Keep 64-10-1 = 53, plus 36 untouched.
	wantBalance(t, w, 100-10-1)
	bob := openWallet(t, &MemStore{})
	fund(t, bob, m, 0)
	got, err := bob.Receive(ctx, m.URL(), sent.Proofs, nil, "")
	// 10 = 8+2: two inputs, fee ceil(0.8)=1.
	if err != nil || got != 9 {
		t.Fatalf("receive %d %v", got, err)
	}
}

func TestTwoDevicesSameProofs(t *testing.T) {
	m := newTestMint(t, 0)
	store := &MemStore{}
	phone := openWallet(t, store)
	fund(t, phone, m, 64)
	mac := openWallet(t, store) // same state, as after a Vault restore
	if _, err := phone.Send(ctx, m.URL(), 64, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := mac.Send(ctx, m.URL(), 64, "", ""); !errors.Is(err, ErrAlreadySpent) {
		t.Fatalf("second device spend: %v", err)
	}
	wantBalance(t, mac, 0) // spent proofs dropped, nothing negative
	wantNoOps(t, mac)
}

func TestCheckStateDropsProofsSpentElsewhere(t *testing.T) {
	m := newTestMint(t, 0)
	store := &MemStore{}
	a := openWallet(t, store)
	fund(t, a, m, 96) // 64+32
	b := openWallet(t, store)
	if _, err := a.Send(ctx, m.URL(), 32, "", ""); err != nil {
		t.Fatal(err)
	}
	rep, err := b.CheckState(ctx, m.URL())
	// Largest first: the 64 proof was spent.
	if err != nil || rep.SpentDropped != 64 {
		t.Fatalf("checkstate %+v %v", rep, err)
	}
	wantBalance(t, b, 32)
}

func TestWarnAt100kNeverRefuses(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, WarnBalanceSats-1)
	if w.Balance().Warn {
		t.Fatal("warn below the line")
	}
	q, _ := w.RequestMint(ctx, m.URL(), 500_000)
	m.payMintQuote(q.ID)
	if _, err := w.ClaimMint(ctx, q.ID); err != nil {
		t.Fatalf("big incoming refused: %v", err)
	}
	if b := w.Balance(); !b.Warn || b.Total != WarnBalanceSats-1+500_000 {
		t.Fatalf("balance %+v", b)
	}
}

func TestBadDLEQRefused(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 0)
	m.badDLEQ = true
	q, _ := w.RequestMint(ctx, m.URL(), 8)
	m.payMintQuote(q.ID)
	if _, err := w.ClaimMint(ctx, q.ID); !errors.Is(err, ErrPending) {
		t.Fatalf("bad DLEQ: %v", err)
	}
	wantBalance(t, w, 0)
	ops := w.Pending()
	if len(ops) != 1 || ops[0].Stuck == "" {
		t.Fatalf("op not kept as stuck: %+v", ops)
	}
}

func TestKeysetIDMustMatchKeys(t *testing.T) {
	m := newTestMint(t, 0)
	keys := m.ks.DerivePublic()
	if err := verifyKeysetID(m.ks.Id, keys); err != nil {
		t.Fatal(err)
	}
	keys[1] = keys[2] // the mint hands out another key under the same id
	if err := verifyKeysetID(m.ks.Id, keys); err == nil {
		t.Fatal("swapped key accepted")
	}
}

func TestSaveFailureNeverCallsMint(t *testing.T) {
	m := newTestMint(t, 0)
	store := &MemStore{}
	w := openWallet(t, store)
	fund(t, w, m, 64)
	store.FailSave = errors.New("disk full")
	if _, err := w.Send(ctx, m.URL(), 10, "", ""); err == nil {
		t.Fatal("send with failing store worked")
	}
	if m.callCount("/v1/swap") != 0 {
		t.Fatal("mint was called before the journal was saved")
	}
	store.FailSave = nil
	wantBalance(t, w, 64)
	wantNoOps(t, w)
}

func TestFileStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w", "wallet.json")
	fs := FileStore{Path: path}
	s, err := fs.Load()
	if err != nil || len(s.Mints) != 0 {
		t.Fatalf("empty load: %v", err)
	}
	s.addProofs("https://mint.test", cashu.Proofs{{Amount: 2, Id: "00aa", Secret: "s", C: "c"}})
	if err := fs.Save(s); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", st.Mode(), err)
	}
	got, err := fs.Load()
	if err != nil || got.Mints["https://mint.test"].Proofs.Amount() != 2 {
		t.Fatalf("reload: %+v %v", got, err)
	}
	os.WriteFile(path, []byte(`{"version":99}`), 0o600)
	if _, err := fs.Load(); err == nil {
		t.Fatal("newer state version loaded")
	}
}

func TestNormalizeMintURL(t *testing.T) {
	good := map[string]string{
		"https://Mint.Example.com/":      "https://mint.example.com",
		" https://mint.example.com/sub ": "https://mint.example.com/sub",
		"http://127.0.0.1:3338":          "http://127.0.0.1:3338",
	}
	for in, want := range good {
		if got, err := NormalizeMintURL(in); err != nil || got != want {
			t.Errorf("%q -> %q %v, want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"http://mint.example.com", "ftp://x", "mint.example.com", "https://u:p@mint.example.com", "https://mint.example.com/?a=1"} {
		if _, err := NormalizeMintURL(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestRemoveMintNeedsEmptyBalance(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 8)
	if err := w.RemoveMint(m.URL()); err == nil {
		t.Fatal("removed a mint holding sats")
	}
	m2 := newTestMint(t, 0)
	fund(t, w, m2, 0)
	if err := w.RemoveMint(m2.URL()); err != nil {
		t.Fatal(err)
	}
	if len(w.Mints()) != 1 {
		t.Fatalf("mints %v", w.Mints())
	}
}
