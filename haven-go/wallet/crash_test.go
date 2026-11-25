package wallet

// Kill the app at each step of each money op (§4.3): reopen from the same file,
// run Recover, and check no sat was lost or made up.

import (
	"errors"
	"path/filepath"
	"testing"
)

type crashCase struct {
	name string
	// setup funds the wallet; run does the op. Both get a fresh wallet on the
	// same file store.
	setup func(t *testing.T, w *Wallet, m *testMint) any
	run   func(w *Wallet, m *testMint, arg any) error
	step  string // hook step, or "" for a lost mint reply
	path  string // mint path whose reply is lost (step == "")
	// wantBal/wantRes after Recover.
	wantBal, wantRes uint64
}

func crashCases() []crashCase {
	send := func(t *testing.T, w *Wallet, m *testMint) any { fund(t, w, m, 100); return nil }
	sendRun := func(w *Wallet, m *testMint, _ any) error { _, err := w.Send(ctx, m.URL(), 30, "", ""); return err }

	mintSetup := func(t *testing.T, w *Wallet, m *testMint) any {
		fund(t, w, m, 0)
		q, err := w.RequestMint(ctx, m.URL(), 100)
		if err != nil {
			t.Fatal(err)
		}
		m.payMintQuote(q.ID)
		return q.ID
	}
	mintRun := func(w *Wallet, m *testMint, arg any) error { _, err := w.ClaimMint(ctx, arg.(string)); return err }

	meltSetup := func(t *testing.T, w *Wallet, m *testMint) any {
		fund(t, w, m, 100)
		q, err := w.QuoteMelt(ctx, m.URL(), m.invoice(10))
		if err != nil {
			t.Fatal(err)
		}
		return q
	}
	meltRun := func(w *Wallet, m *testMint, arg any) error { _, err := w.Melt(ctx, arg.(MeltQuote)); return err }

	recvSetup := func(t *testing.T, w *Wallet, m *testMint) any {
		fund(t, w, m, 0)
		other := openWallet(t, &MemStore{})
		fund(t, other, m, 64)
		r, err := other.Send(ctx, m.URL(), 30, "", "")
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	recvRun := func(w *Wallet, m *testMint, arg any) error {
		_, err := w.Receive(ctx, m.URL(), arg.(Reserved).Proofs, nil, "")
		return err
	}

	reclaimSetup := func(t *testing.T, w *Wallet, m *testMint) any {
		fund(t, w, m, 50)
		r, err := w.Send(ctx, m.URL(), 20, "", "")
		if err != nil {
			t.Fatal(err)
		}
		return r.ID
	}
	reclaimRun := func(w *Wallet, m *testMint, arg any) error { _, err := w.Reclaim(ctx, arg.(string)); return err }

	// A crash before the mint call looks the same to Recover as a request
	// still in flight, so Recover sends it again and the op finishes.
	return []crashCase{
		{"send/before-mint", send, sendRun, "swap:journaled", "", 70, 30},
		{"send/after-mint", send, sendRun, "swap:answered", "", 70, 30},
		{"send/lost-reply", send, sendRun, "", "/v1/swap", 70, 30},
		{"mint/before-mint", mintSetup, mintRun, "mint:journaled", "", 100, 0},
		{"mint/after-mint", mintSetup, mintRun, "mint:answered", "", 100, 0},
		{"mint/lost-reply", mintSetup, mintRun, "", "/v1/mint/bolt11", 100, 0},
		{"melt/before-mint", meltSetup, meltRun, "melt:journaled", "", 89, 0},
		{"melt/after-mint", meltSetup, meltRun, "melt:answered", "", 89, 0},
		{"melt/lost-reply", meltSetup, meltRun, "", "/v1/melt/bolt11", 89, 0},
		{"receive/before-mint", recvSetup, recvRun, "swap:journaled", "", 30, 0},
		{"receive/after-mint", recvSetup, recvRun, "swap:answered", "", 30, 0},
		{"receive/lost-reply", recvSetup, recvRun, "", "/v1/swap", 30, 0},
		{"reclaim/before-mint", reclaimSetup, reclaimRun, "swap:journaled", "", 50, 0},
		{"reclaim/after-mint", reclaimSetup, reclaimRun, "swap:answered", "", 50, 0},
		{"reclaim/lost-reply", reclaimSetup, reclaimRun, "", "/v1/swap", 50, 0},
	}
}

func TestCrashAtEachStep(t *testing.T) {
	for _, tc := range crashCases() {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestMint(t, 0)
			store := FileStore{Path: filepath.Join(t.TempDir(), "wallet.json")}
			w := openWallet(t, store)
			arg := tc.setup(t, w, m)

			if tc.step != "" {
				w.hook = func(s string) error {
					if s == tc.step {
						return errCrash
					}
					return nil
				}
			} else {
				m.mu.Lock()
				m.dropReply[tc.path] = 1
				m.mu.Unlock()
			}
			err := tc.run(w, m, arg)
			if tc.step != "" && !errors.Is(err, errCrash) {
				t.Fatalf("op did not stop at %s: %v", tc.step, err)
			}
			if tc.step == "" && !errors.Is(err, ErrPending) {
				t.Fatalf("lost reply: %v, want ErrPending", err)
			}

			// The app died: everything in memory is gone.
			w2 := openWallet(t, store)
			if len(w2.Pending()) != 1 {
				t.Fatalf("journal has %d ops after the crash, want 1", len(w2.Pending()))
			}
			rep := w2.Recover(ctx)
			if rep.Left != 0 || len(rep.Errors) != 0 {
				t.Fatalf("recover: %+v", rep)
			}
			b := w2.Balance()
			if b.Total != tc.wantBal || b.Reserved != tc.wantRes {
				t.Fatalf("after recover: balance %d reserved %d, want %d/%d", b.Total, b.Reserved, tc.wantBal, tc.wantRes)
			}
			wantNoOps(t, w2)
			// Every proof we kept must really be spendable at the mint.
			if rep, err := w2.CheckState(ctx, m.URL()); err != nil || rep.SpentDropped != 0 {
				t.Fatalf("kept proofs the mint calls spent: %+v %v", rep, err)
			}
			// Recover again is a no-op.
			if rep := w2.Recover(ctx); rep.Finished+rep.Undone+rep.Left+len(rep.Errors) != 0 {
				t.Fatalf("second recover: %+v", rep)
			}
		})
	}
}

// A mint with no NUT-09 that loses its reply: the outcome can't be proven, so
// the op stays (stuck) and its sats show as in flight, never dropped.
func TestLostReplyWithoutRestoreStays(t *testing.T) {
	m := newTestMint(t, 0)
	m.noRestore = true
	store := FileStore{Path: filepath.Join(t.TempDir(), "wallet.json")}
	w := openWallet(t, store)
	fund(t, w, m, 100)
	m.dropReply["/v1/swap"] = 1
	if _, err := w.Send(ctx, m.URL(), 30, "", ""); !errors.Is(err, ErrPending) {
		t.Fatalf("lost reply: %v", err)
	}
	w2 := openWallet(t, store)
	rep := w2.Recover(ctx)
	if rep.Left != 1 {
		t.Fatalf("recover: %+v", rep)
	}
	ops := w2.Pending()
	if len(ops) != 1 || ops[0].Stuck == "" {
		t.Fatalf("op not kept as stuck: %+v", ops)
	}
	b := w2.Balance()
	if b.Total+b.InFlight != 100 {
		t.Fatalf("sats went missing: %+v", b)
	}
	// A stuck op does not block new spends from the rest of the balance.
	if b.Total > 0 {
		if _, err := w2.Send(ctx, m.URL(), 1, "", ""); err != nil {
			t.Fatalf("send next to a stuck op: %v", err)
		}
	}
}

// Recover with the mint down keeps everything for next time.
func TestRecoverWithMintDown(t *testing.T) {
	m := newTestMint(t, 0)
	store := FileStore{Path: filepath.Join(t.TempDir(), "wallet.json")}
	w := openWallet(t, store)
	fund(t, w, m, 100)
	w.hook = func(s string) error {
		if s == "swap:answered" {
			return errCrash
		}
		return nil
	}
	w.Send(ctx, m.URL(), 30, "", "")
	m.srv.Close()
	w2 := openWallet(t, store)
	if rep := w2.Recover(ctx); rep.Left != 1 || len(rep.Errors) != 1 {
		t.Fatalf("recover with mint down: %+v", rep)
	}
	if len(w2.Pending()) != 1 {
		t.Fatal("op dropped while the mint was down")
	}
}
