package wallet

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"testing"

	"github.com/elnosh/gonuts/cashu/nuts/nut04"
)

// Regression tests for Tron's PR 2533 review: each one lost sats before.

// lateRT drops our first request to path on the floor (the caller sees a
// timeout) and delivers it to the mint later, when release is closed.
type lateRT struct {
	path    string
	release chan struct{}
	done    chan struct{}
	used    bool
}

func newLateRT(path string) *lateRT {
	return &lateRT{path: path, release: make(chan struct{}), done: make(chan struct{})}
}

func (g *lateRT) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Path != g.path || g.used {
		return http.DefaultTransport.RoundTrip(r)
	}
	g.used = true
	body, _ := io.ReadAll(r.Body)
	r.Body.Close()
	u, hdr := r.URL.String(), r.Header.Clone()
	go func() {
		defer close(g.done)
		<-g.release
		req, _ := http.NewRequest(http.MethodPost, u, bytes.NewReader(body))
		req.Header = hdr
		if resp, err := http.DefaultTransport.RoundTrip(req); err == nil {
			resp.Body.Close()
		}
	}()
	return nil, errors.New("timeout (simulated)")
}

func useTransport(w *Wallet, m *testMint, rt http.RoundTripper) {
	w.mu.Lock()
	w.clients[m.URL()].HTTP = &http.Client{Transport: rt}
	w.mu.Unlock()
}

// #1: a mint quote that reads PENDING at Recover is kept, not dropped.
func TestRecoverKeepsMintQuotePending(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 0)
	q, err := w.RequestMint(ctx, m.URL(), 100)
	if err != nil {
		t.Fatal(err)
	}
	m.payMintQuote(q.ID)
	w.hook = func(s string) error {
		if s == "mint:journaled" {
			return errCrash
		}
		return nil
	}
	w.ClaimMint(ctx, q.ID)
	w.hook = nil
	op := w.Pending()[0]
	m.mu.Lock()
	m.mintQuotes[q.ID].state = nut04.Pending
	m.mu.Unlock()
	if rep := w.Recover(ctx); rep.Left != 1 || len(w.Pending()) != 1 {
		t.Fatalf("recover with quote PENDING: %+v, %d ops", rep, len(w.Pending()))
	}
	// The mint finishes issuing our journaled outputs.
	m.mu.Lock()
	m.mintQuotes[q.ID].state = nut04.Paid
	m.mu.Unlock()
	c, _ := NewClient(m.URL())
	if _, err := c.Mint(ctx, q.ID, blinded(op.Outputs)); err != nil {
		t.Fatal(err)
	}
	if rep := w.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover after issue: %+v", rep)
	}
	wantBalance(t, w, 100)
	wantNoOps(t, w)
}

// #2 (swap): a timed-out swap that lands after Recover loses nothing.
func TestRecoverLateSwap(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	g := newLateRT("/v1/swap")
	useTransport(w, m, g)
	if _, err := w.Send(ctx, m.URL(), 30, "", ""); !errors.Is(err, ErrPending) {
		t.Fatalf("send: %v, want ErrPending", err)
	}
	if rep := w.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover: %+v", rep)
	}
	close(g.release)
	<-g.done
	if rep, err := w.CheckState(ctx, m.URL()); err != nil || rep.SpentDropped != 0 {
		t.Fatalf("checkstate: %+v %v", rep, err)
	}
	if b := w.Balance(); b.Total != 70 || b.Reserved != 30 {
		t.Fatalf("balance %d reserved %d, want 70/30", b.Total, b.Reserved)
	}
	wantNoOps(t, w)
}

// #2 (swap, other order): the late copy lands before Recover re-sends.
func TestRecoverSwapLandedFirst(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	g := newLateRT("/v1/swap")
	useTransport(w, m, g)
	if _, err := w.Send(ctx, m.URL(), 30, "", ""); !errors.Is(err, ErrPending) {
		t.Fatalf("send: %v, want ErrPending", err)
	}
	close(g.release)
	<-g.done
	if rep := w.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover: %+v", rep)
	}
	if b := w.Balance(); b.Total != 70 || b.Reserved != 30 {
		t.Fatalf("balance %d reserved %d, want 70/30", b.Total, b.Reserved)
	}
	wantNoOps(t, w)
}

// #2 (melt): a timed-out melt that lands after Recover loses nothing.
func TestRecoverLateMelt(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 100)
	q, err := w.QuoteMelt(ctx, m.URL(), m.invoice(10))
	if err != nil {
		t.Fatal(err)
	}
	g := newLateRT("/v1/melt/bolt11")
	useTransport(w, m, g)
	if _, err := w.Melt(ctx, q); !errors.Is(err, ErrPending) {
		t.Fatalf("melt: %v, want ErrPending", err)
	}
	if rep := w.Recover(ctx); rep.Finished != 1 {
		t.Fatalf("recover: %+v", rep)
	}
	close(g.release)
	<-g.done
	if rep, err := w.CheckState(ctx, m.URL()); err != nil || rep.SpentDropped != 0 {
		t.Fatalf("checkstate: %+v %v", rep, err)
	}
	wantBalance(t, w, 89) // 100 - 10 - 1 Lightning fee
	wantNoOps(t, w)
}

// #3: a refused swap keeps an input another device's melt holds as pending.
func TestSwapRefusedKeepsPendingInput(t *testing.T) {
	m := newTestMint(t, 0)
	w := openWallet(t, &MemStore{})
	fund(t, w, m, 96) // 64 + 32
	m.mu.Lock()
	for _, p := range w.mintProofs(m.URL()) {
		y, _ := proofY(p.Secret)
		if p.Amount == 64 {
			m.spent[y] = true // spent by another device
		} else {
			m.pending[y] = true // in another device's melt
		}
	}
	m.mu.Unlock()
	if _, err := w.Send(ctx, m.URL(), 90, "", ""); !errors.Is(err, ErrPending) {
		t.Fatalf("send: %v, want ErrPending", err)
	}
	if len(w.Pending()) != 1 {
		t.Fatalf("op dropped while an input is pending")
	}
	m.mu.Lock()
	m.pending = map[string]bool{} // that melt failed: the 32 is unspent again
	m.mu.Unlock()
	if rep := w.Recover(ctx); rep.Undone != 1 {
		t.Fatalf("recover: %+v", rep)
	}
	wantBalance(t, w, 32)
	wantNoOps(t, w)
}

// Should-fix 4: overshoot at a mint without NUT-08 is refused before any
// mint call; with NUT-08 the overshoot comes back as change.
func TestMeltOvershootNeedsNUT08(t *testing.T) {
	for _, noChange := range []bool{true, false} {
		m := newTestMint(t, 0)
		m.noChange = noChange
		w := openWallet(t, &MemStore{})
		fund(t, w, m, 1024) // one 1024 proof
		q, err := w.QuoteMelt(ctx, m.URL(), m.invoice(10))
		if err != nil {
			t.Fatal(err)
		}
		_, err = w.Melt(ctx, q)
		if noChange {
			if !errors.Is(err, ErrNoChange) {
				t.Fatalf("no NUT-08: %v, want ErrNoChange", err)
			}
			if m.callCount("/v1/melt/bolt11") != 0 {
				t.Fatalf("melt sent to a mint that can't return change")
			}
			wantBalance(t, w, 1024)
		} else {
			if err != nil {
				t.Fatal(err)
			}
			wantBalance(t, w, 1024-10-1)
		}
		wantNoOps(t, w)
	}
}
