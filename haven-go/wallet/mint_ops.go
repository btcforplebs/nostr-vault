package wallet

import (
	"context"
	"errors"
	"fmt"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut04"
)

// ErrQuoteIssued means the quote's ecash was already issued (to another of
// our devices, or before a crash Recover already handled).
var ErrQuoteIssued = errors.New("wallet: this invoice's ecash was already issued")

// RequestMint asks mint for a Lightning invoice of amount sats (NUT-04) and
// keeps the quote, so the invoice survives a restart. Pay the returned
// Request, then call ClaimMint.
func (w *Wallet) RequestMint(ctx context.Context, mint string, amount uint64) (MintQuote, error) {
	if amount == 0 {
		return MintQuote{}, fmt.Errorf("wallet: amount must be above 0")
	}
	c, err := w.client(mint)
	if err != nil {
		return MintQuote{}, err
	}
	resp, err := c.MintQuote(ctx, amount)
	if err != nil {
		return MintQuote{}, err
	}
	if resp.Quote == "" || resp.Request == "" {
		return MintQuote{}, fmt.Errorf("wallet: mint gave an empty quote")
	}
	q := MintQuote{ID: resp.Quote, Mint: mint, Amount: amount, Request: resp.Request, Expiry: resp.Expiry, Created: w.now().Unix()}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	return q, w.commit(func(s *State) error {
		s.MintQuotes = append(s.MintQuotes, q)
		return nil
	})
}

// MintQuotes lists open receive invoices.
func (w *Wallet) MintQuotes() []MintQuote {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state.clone().MintQuotes
}

// ClaimMint mints the ecash for a paid quote. It returns ErrNotPaid while the
// invoice is unpaid (the quote is kept).
func (w *Wallet) ClaimMint(ctx context.Context, quoteID string) (uint64, error) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	w.mu.Lock()
	var q MintQuote
	found := false
	for _, x := range w.state.MintQuotes {
		if x.ID == quoteID {
			q, found = x, true
		}
	}
	w.mu.Unlock()
	if !found {
		return 0, fmt.Errorf("wallet: no receive invoice %s", quoteID)
	}
	c, err := w.client(q.Mint)
	if err != nil {
		return 0, err
	}
	if w.mintBusy(q.Mint) {
		return 0, ErrBusy
	}
	st, err := c.MintQuoteState(ctx, q.ID)
	if err != nil {
		return 0, err
	}
	switch st.State {
	case nut04.Paid:
	case nut04.Issued:
		return 0, w.dropQuote(q.ID, ErrQuoteIssued)
	default:
		return 0, ErrNotPaid
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return 0, err
	}
	ks, err := activeKeyset(sets)
	if err != nil {
		return 0, err
	}
	outs, err := newOutputs(ks, splitAmount(q.Amount), RoleKeep, "")
	if err != nil {
		return 0, err
	}
	op := Op{ID: w.newID(), Kind: OpMint, Mint: q.Mint, Outputs: outs, Quote: q.ID, Created: w.now().Unix()}
	if err := w.journal(op); err != nil {
		return 0, err
	}
	if err := w.step("mint:journaled"); err != nil {
		return 0, err
	}
	resp, err := c.Mint(ctx, q.ID, blinded(outs))
	if err := w.step("mint:answered"); err != nil {
		return 0, err
	}
	if err != nil {
		if !IsDefinite(err) {
			return 0, fmt.Errorf("%w: %v", ErrPending, err)
		}
		// The mint refused: nothing was signed. Drop the op; keep the quote
		// unless it says the quote was already issued.
		var me *MintError
		issued := errors.As(err, &me) && me.Code == cashu.MintQuoteAlreadyIssuedErrCode
		cerr := w.commit(func(s *State) error {
			s.removeOp(op.ID)
			if issued {
				removeQuote(s, q.ID)
			}
			return nil
		})
		if cerr != nil {
			return 0, cerr
		}
		if issued {
			return 0, ErrQuoteIssued
		}
		return 0, err
	}
	proofs, err := unblindAll(outs, resp.Signatures, sets, false)
	if err != nil {
		w.markStuck(op.ID, err.Error())
		return 0, fmt.Errorf("%w: %v", ErrPending, err)
	}
	return q.Amount, w.applyMint(op, proofs)
}

func (w *Wallet) applyMint(op Op, proofs []cashu.Proof) error {
	return w.commit(func(s *State) error {
		s.addProofs(op.Mint, proofs)
		s.removeOp(op.ID)
		removeQuote(s, op.Quote)
		return nil
	})
}

func (w *Wallet) dropQuote(id string, ret error) error {
	if err := w.commit(func(s *State) error { removeQuote(s, id); return nil }); err != nil {
		return err
	}
	return ret
}

func removeQuote(s *State, id string) {
	kept := s.MintQuotes[:0]
	for _, q := range s.MintQuotes {
		if q.ID != id {
			kept = append(kept, q)
		}
	}
	s.MintQuotes = kept
}
