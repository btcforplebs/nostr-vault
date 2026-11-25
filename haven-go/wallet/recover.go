package wallet

import (
	"context"
	"errors"
	"fmt"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut04"
	"github.com/elnosh/gonuts/cashu/nuts/nut05"
)

// RecoverReport says what Recover did.
type RecoverReport struct {
	Finished int      `json:"finished"` // ops the mint had carried out; outputs credited
	Undone   int      `json:"undone"`   // ops the mint never carried out; inputs back
	Left     int      `json:"left"`     // ops still unknown or stuck (kept)
	Errors   []string `json:"errors,omitempty"`
}

// Recover finishes or undoes every journaled op (run it at start, after a
// crash, and after any ErrPending). It never drops an op whose outcome it
// can't prove from the mint's answers.
func (w *Wallet) Recover(ctx context.Context) RecoverReport {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	var rep RecoverReport
	for _, op := range w.Pending() {
		res, err := w.recoverOp(ctx, op)
		switch res {
		case recFinished:
			rep.Finished++
		case recUndone:
			rep.Undone++
		default:
			rep.Left++
		}
		if err != nil {
			rep.Errors = append(rep.Errors, fmt.Sprintf("%s %s: %v", op.Kind, op.ID, err))
		}
	}
	return rep
}

type recResult int

const (
	recLeft recResult = iota
	recFinished
	recUndone
)

func (w *Wallet) recoverOp(ctx context.Context, op Op) (recResult, error) {
	c, err := w.client(op.Mint)
	if err != nil {
		return recLeft, err
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return recLeft, err
	}
	switch op.Kind {
	case OpMint:
		return w.recoverMint(ctx, c, op, sets)
	case OpMelt:
		return w.recoverMelt(ctx, c, op, sets)
	default:
		return w.recoverSwap(ctx, c, op, sets)
	}
}

func (w *Wallet) recoverMint(ctx context.Context, c *Client, op Op, sets map[string]Keyset) (recResult, error) {
	st, err := c.MintQuoteState(ctx, op.Quote)
	if err != nil {
		return recLeft, err
	}
	switch st.State {
	case nut04.Issued:
		return w.restoreAndApply(ctx, c, op, sets)
	case nut04.Paid:
		// The mint never signed: ask again with the same outputs.
		resp, err := c.Mint(ctx, op.Quote, blinded(op.Outputs))
		if err != nil {
			var me *MintError
			if errors.As(err, &me) && me.Code == cashu.MintQuoteAlreadyIssuedErrCode {
				return w.restoreAndApply(ctx, c, op, sets)
			}
			return recLeft, err
		}
		proofs, err := unblindAll(op.Outputs, resp.Signatures, sets, false)
		if err != nil {
			return recLeft, err
		}
		return recFinished, w.applyMint(op, proofs)
	default:
		// Unpaid: nothing happened. Keep the quote, drop the op.
		return recUndone, w.commit(func(s *State) error { s.removeOp(op.ID); return nil })
	}
}

func (w *Wallet) recoverMelt(ctx context.Context, c *Client, op Op, sets map[string]Keyset) (recResult, error) {
	st, err := c.MeltQuoteState(ctx, op.Quote)
	if err != nil {
		return recLeft, err
	}
	switch st.State {
	case nut05.Paid:
		if len(op.Outputs) == 0 {
			return recFinished, w.commit(func(s *State) error { s.removeOp(op.ID); return nil })
		}
		// Change may be in the quote reply (NUT-08); else ask NUT-09.
		if len(st.Change) > 0 {
			if proofs, err := unblindAll(op.Outputs, st.Change, sets, true); err == nil {
				return recFinished, w.applyMint(op, proofs)
			}
		}
		return w.restoreAndApply(ctx, c, op, sets)
	case nut05.Pending:
		return recLeft, nil
	default:
		err := w.meltNotPaid(ctx, c, op, nil)
		if errors.Is(err, ErrPending) {
			return recLeft, nil
		}
		if err != nil {
			return recLeft, err
		}
		return recUndone, nil
	}
}

func (w *Wallet) recoverSwap(ctx context.Context, c *Client, op Op, sets map[string]Keyset) (recResult, error) {
	states, err := w.inputStates(ctx, c, op.Inputs)
	if err != nil {
		return recLeft, err
	}
	anySpent := false
	for _, s := range states {
		if s == statePending {
			return recLeft, nil
		}
		if s == stateSpent {
			anySpent = true
		}
	}
	if anySpent {
		return w.restoreAndApply(ctx, c, op, sets)
	}
	// The mint never saw the swap.
	if op.Kind == OpReceive {
		// Not our proofs yet: try the swap again with the same outputs.
		resp, err := c.Swap(ctx, op.Inputs, blinded(op.Outputs))
		if err != nil {
			if !IsDefinite(err) {
				return recLeft, err
			}
			if rerr := w.swapRefused(ctx, c, op, err); errors.Is(rerr, ErrPending) {
				return recLeft, rerr
			}
			return recUndone, nil
		}
		proofs, err := unblindAll(op.Outputs, resp.Signatures, sets, false)
		if err != nil {
			return recLeft, err
		}
		return recFinished, w.applySwap(op, proofs)
	}
	return recUndone, w.commit(func(s *State) error {
		s.removeOp(op.ID)
		if op.Kind == OpSwap {
			s.addProofs(op.Mint, unspentOnly(op.Inputs, nil))
		}
		return nil
	})
}

// restoreAndApply asks the mint (NUT-09) for signatures on the op's outputs.
//   - all found: credit them and close the op.
//   - some found: credit those, keep the op as stuck.
//   - none found (and the mint answered): the mint never signed ours, so the
//     spent inputs went elsewhere (another device). Unspent inputs go back.
//   - mint can't answer: keep the op.
func (w *Wallet) restoreAndApply(ctx context.Context, c *Client, op Op, sets map[string]Keyset) (recResult, error) {
	resp, err := c.Restore(ctx, blinded(op.Outputs))
	if err != nil {
		if IsDefinite(err) {
			w.markStuck(op.ID, "mint can't restore outputs: "+err.Error())
		}
		return recLeft, err
	}
	if len(resp.Outputs) != len(resp.Signatures) {
		return recLeft, fmt.Errorf("mint restore reply is uneven")
	}
	byB := map[string]cashu.BlindedSignature{}
	for i, o := range resp.Outputs {
		byB[o.B_] = resp.Signatures[i]
	}
	found := map[int]cashu.Proof{}
	for i, o := range op.Outputs {
		sig, ok := byB[o.B]
		if !ok {
			continue
		}
		p, err := unblindOne(o, sig, sets)
		if err != nil {
			return recLeft, err
		}
		found[i] = p
	}
	need := 0
	for _, o := range op.Outputs {
		if o.Role != RoleChange {
			need++
		}
	}
	switch {
	case len(found) >= need && (need > 0 || op.Kind == OpMelt || op.Kind == OpMint):
		return recFinished, w.applyFound(op, found, true)
	case len(found) > 0:
		return recLeft, w.applyFound(op, found, false)
	}
	// None of ours signed.
	if op.Kind == OpMint {
		w.markStuck(op.ID, "quote issued but none of these outputs were signed")
		return recLeft, nil
	}
	states, err := w.inputStates(ctx, c, op.Inputs)
	if err != nil {
		return recLeft, err
	}
	spent := map[string]bool{}
	for secret, st := range states {
		if st == statePending {
			return recLeft, nil
		}
		if st == stateSpent {
			spent[secret] = true
		}
	}
	return recUndone, w.commit(func(s *State) error {
		s.removeOp(op.ID)
		switch op.Kind {
		case OpSwap, OpMelt:
			s.addProofs(op.Mint, unspentOnly(op.Inputs, spent))
		case OpReclaim:
			dropReservedProofs(s, op.Reserved, spent)
		}
		return nil
	})
}

// applyFound credits restored outputs by role. With closeOp the op ends;
// without, it stays (stuck) and a later Recover can find the rest (adding is
// idempotent by secret).
func (w *Wallet) applyFound(op Op, found map[int]cashu.Proof, closeOp bool) error {
	return w.commit(func(s *State) error {
		var keep, send cashu.Proofs
		for i, p := range found {
			if op.Outputs[i].Role == RoleSend {
				send = append(send, p)
			} else {
				keep = append(keep, p)
			}
		}
		s.addProofs(op.Mint, keep)
		if len(send) > 0 {
			if j := s.findReserved(op.ID); j >= 0 {
				have := map[string]bool{}
				for _, p := range s.Reserved[j].Proofs {
					have[p.Secret] = true
				}
				for _, p := range send {
					if !have[p.Secret] {
						s.Reserved[j].Proofs = append(s.Reserved[j].Proofs, p)
					}
				}
			} else {
				s.Reserved = append(s.Reserved, Reserved{ID: op.ID, Mint: op.Mint, Proofs: send, Memo: op.Memo, Created: op.Created})
			}
		}
		if !closeOp {
			if i := s.findOp(op.ID); i >= 0 {
				s.Ops[i].Stuck = fmt.Sprintf("restored %d of %d outputs", len(found), len(op.Outputs))
			}
			return nil
		}
		if op.Kind == OpReclaim {
			if i := s.findReserved(op.Reserved); i >= 0 {
				s.Reserved = append(s.Reserved[:i], s.Reserved[i+1:]...)
			}
		}
		if op.Kind == OpMint {
			removeQuote(s, op.Quote)
		}
		s.removeOp(op.ID)
		return nil
	})
}
