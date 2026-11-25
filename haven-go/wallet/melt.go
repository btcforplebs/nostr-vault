package wallet

import (
	"context"
	"fmt"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut05"
)

// MeltQuote is what paying an invoice will cost (show it before sending, §2).
type MeltQuote struct {
	ID         string `json:"id"`
	Mint       string `json:"mint"`
	Amount     uint64 `json:"amount"`
	FeeReserve uint64 `json:"fee_reserve"`
	Expiry     uint64 `json:"expiry,omitempty"`
}

// MeltResult is a paid invoice.
type MeltResult struct {
	Preimage string `json:"preimage,omitempty"`
	Spent    uint64 `json:"spent"`  // inputs given up
	Change   uint64 `json:"change"` // returned to the balance
}

// QuoteMelt asks mint what paying bolt11 costs (NUT-05). Nothing is spent.
func (w *Wallet) QuoteMelt(ctx context.Context, mint, bolt11 string) (MeltQuote, error) {
	c, err := w.client(mint)
	if err != nil {
		return MeltQuote{}, err
	}
	r, err := c.MeltQuote(ctx, bolt11)
	if err != nil {
		return MeltQuote{}, err
	}
	if r.Quote == "" || r.Amount == 0 {
		return MeltQuote{}, fmt.Errorf("wallet: mint gave an empty melt quote")
	}
	return MeltQuote{ID: r.Quote, Mint: mint, Amount: r.Amount, FeeReserve: r.FeeReserve, Expiry: r.Expiry}, nil
}

// Melt pays a quoted invoice from mint. Excess (the unused fee reserve and any
// selection overshoot) comes back as NUT-08 change. If the payment is still
// in flight it returns ErrPending; Recover finishes it.
func (w *Wallet) Melt(ctx context.Context, q MeltQuote) (MeltResult, error) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	c, err := w.client(q.Mint)
	if err != nil {
		return MeltResult{}, err
	}
	if w.mintBusy(q.Mint) {
		return MeltResult{}, ErrBusy
	}
	// Re-read the quote from the mint: the amount we pay is the mint's, not
	// the caller's copy.
	st, err := c.MeltQuoteState(ctx, q.ID)
	if err != nil {
		return MeltResult{}, err
	}
	if st.State != nut05.Unpaid {
		return MeltResult{}, fmt.Errorf("wallet: melt quote is %s, not unpaid", st.State)
	}
	if st.Amount != q.Amount || st.FeeReserve > q.FeeReserve {
		return MeltResult{}, fmt.Errorf("wallet: mint changed the quote (%d+%d, shown %d+%d)", st.Amount, st.FeeReserve, q.Amount, q.FeeReserve)
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return MeltResult{}, err
	}
	ks, err := activeKeyset(sets)
	if err != nil {
		return MeltResult{}, err
	}
	inputs, fee, err := selectProofs(w.mintProofs(q.Mint), st.Amount+st.FeeReserve, sets)
	if err != nil {
		return MeltResult{}, err
	}
	// Anything above amount + fee reserve comes back only as NUT-08 change.
	// A mint without NUT-08 would keep it, so refuse before journaling.
	if over := inputs.Amount() - fee - st.Amount - st.FeeReserve; over > 0 {
		info, err := c.Info(ctx)
		if err != nil {
			return MeltResult{}, fmt.Errorf("mint info: %w", err)
		}
		if !info.Nuts.Nut08.Supported {
			return MeltResult{}, fmt.Errorf("%w: this mint can't return change (no NUT-08), so paying would give up %d extra sats", ErrNoChange, over)
		}
	}
	change, err := blankOutputs(ks, inputs.Amount()-st.Amount-fee)
	if err != nil {
		return MeltResult{}, err
	}
	op := Op{ID: w.newID(), Kind: OpMelt, Mint: q.Mint, Inputs: inputs, Outputs: change, Quote: q.ID, Created: w.now().Unix()}
	if err := w.journal(op); err != nil {
		return MeltResult{}, err
	}
	if err := w.step("melt:journaled"); err != nil {
		return MeltResult{}, err
	}
	resp, err := c.Melt(ctx, q.ID, inputs, blinded(change))
	if err := w.step("melt:answered"); err != nil {
		return MeltResult{}, err
	}
	if err != nil {
		if !IsDefinite(err) {
			return MeltResult{}, fmt.Errorf("%w: %v", ErrPending, err)
		}
		return MeltResult{}, w.meltNotPaid(ctx, c, op, err)
	}
	switch resp.State {
	case nut05.Paid:
		proofs, uerr := unblindAll(change, resp.Change, sets, true)
		if uerr != nil {
			// Paid, but the change reply is bad: keep the op so Recover
			// fetches the change with NUT-09.
			w.markStuck(op.ID, uerr.Error())
			return MeltResult{Preimage: resp.Preimage, Spent: inputs.Amount()}, fmt.Errorf("%w: %v", ErrPending, uerr)
		}
		res := MeltResult{Preimage: resp.Preimage, Spent: inputs.Amount(), Change: cashu.Proofs(proofs).Amount()}
		return res, w.applyMint(op, proofs) // credits change, closes op
	case nut05.Pending:
		return MeltResult{}, ErrPending
	default:
		return MeltResult{}, w.meltNotPaid(ctx, c, op, fmt.Errorf("wallet: invoice not paid (%s)", resp.State))
	}
}

// meltNotPaid puts back the inputs the mint did not keep. Inputs the mint
// holds as pending keep the op open for Recover.
func (w *Wallet) meltNotPaid(ctx context.Context, c *Client, op Op, cause error) error {
	states, err := w.inputStates(ctx, c, op.Inputs)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrPending, err)
	}
	spent := map[string]bool{}
	for secret, st := range states {
		switch st {
		case statePending:
			return fmt.Errorf("%w: %v", ErrPending, cause)
		case stateSpent:
			spent[secret] = true
		}
	}
	if err := w.commit(func(s *State) error {
		s.removeOp(op.ID)
		s.addProofs(op.Mint, unspentOnly(op.Inputs, spent))
		return nil
	}); err != nil {
		return err
	}
	return cause
}
