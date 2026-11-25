package wallet

import (
	"context"
	"fmt"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut11"
	"github.com/elnosh/gonuts/cashu/nuts/nut12"
)

// Send swaps proofs at mint into exactly amount sats to hand to someone, and
// keeps the change. lockTo, when set, locks the sent proofs to that pubkey
// (NUT-11 P2PK, for a nutzap). The sent proofs go into Reserved (not the
// balance) and are returned; CheckState drops them once claimed.
func (w *Wallet) Send(ctx context.Context, mint string, amount uint64, lockTo, memo string) (Reserved, error) {
	if amount == 0 {
		return Reserved{}, fmt.Errorf("wallet: amount must be above 0")
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	c, err := w.client(mint)
	if err != nil {
		return Reserved{}, err
	}
	if w.mintBusy(mint) {
		return Reserved{}, ErrBusy
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return Reserved{}, err
	}
	ks, err := activeKeyset(sets)
	if err != nil {
		return Reserved{}, err
	}
	inputs, fee, err := selectProofs(w.mintProofs(mint), amount, sets)
	if err != nil {
		return Reserved{}, err
	}
	sendOuts, err := newOutputs(ks, splitAmount(amount), RoleSend, lockTo)
	if err != nil {
		return Reserved{}, err
	}
	keepOuts, err := newOutputs(ks, splitAmount(inputs.Amount()-amount-fee), RoleKeep, "")
	if err != nil {
		return Reserved{}, err
	}
	op := Op{ID: w.newID(), Kind: OpSwap, Mint: mint, Inputs: inputs,
		Outputs: append(sendOuts, keepOuts...), Memo: memo, Created: w.now().Unix()}
	if err := w.runSwap(ctx, c, op, sets); err != nil {
		return Reserved{}, err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if i := w.state.findReserved(op.ID); i >= 0 {
		return w.state.clone().Reserved[i], nil
	}
	return Reserved{}, fmt.Errorf("wallet: sent proofs missing after swap")
}

// Receive swaps someone else's proofs at mint into new proofs of ours.
// signKey, when set, signs P2PK-locked inputs (a nutzap locked to our wallet
// key). It returns the sats added. A big amount is never refused (the 100k
// line only warns).
func (w *Wallet) Receive(ctx context.Context, mint string, proofs cashu.Proofs, signKey *btcec.PrivateKey, memo string) (uint64, error) {
	if len(proofs) == 0 {
		return 0, fmt.Errorf("wallet: no proofs")
	}
	if cashu.CheckDuplicateProofs(proofs) {
		return 0, fmt.Errorf("wallet: duplicate proofs")
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	c, err := w.client(mint)
	if err != nil {
		return 0, err
	}
	if w.mintBusy(mint) {
		return 0, ErrBusy
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return 0, err
	}
	ks, err := activeKeyset(sets)
	if err != nil {
		return 0, err
	}
	inputs := make(cashu.Proofs, len(proofs))
	for i, p := range proofs {
		set, ok := sets[p.Id]
		if !ok {
			return 0, fmt.Errorf("wallet: proof from keyset %s is not from %s", p.Id, mint)
		}
		if p.DLEQ != nil {
			K, err := set.pubkey(p.Amount)
			if err != nil || !nut12.VerifyProofDLEQ(p, K) {
				return 0, fmt.Errorf("wallet: proof failed its DLEQ check")
			}
		}
		p.Witness = ""
		inputs[i] = p
	}
	if signKey != nil {
		if inputs, err = nut11.AddSignatureToInputs(inputs, signKey); err != nil {
			return 0, err
		}
	}
	fee := inputFee(inputs, sets)
	total := inputs.Amount()
	if total <= fee {
		return 0, fmt.Errorf("wallet: %d sats can't cover the mint's %d sat fee", total, fee)
	}
	outs, err := newOutputs(ks, splitAmount(total-fee), RoleKeep, "")
	if err != nil {
		return 0, err
	}
	op := Op{ID: w.newID(), Kind: OpReceive, Mint: mint, Inputs: inputs, Outputs: outs, Memo: memo, Created: w.now().Unix()}
	if err := w.runSwap(ctx, c, op, sets); err != nil {
		return 0, err
	}
	return total - fee, nil
}

// Reclaim swaps a Reserved set (sent, never claimed) back into the balance.
// If the mint says it was claimed meanwhile, the set is dropped and
// ErrAlreadySpent returned. Proofs locked to someone else's key can't be
// reclaimed: the mint refuses and the set stays.
func (w *Wallet) Reclaim(ctx context.Context, reservedID string) (uint64, error) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	w.mu.Lock()
	i := w.state.findReserved(reservedID)
	var r Reserved
	if i >= 0 {
		r = w.state.clone().Reserved[i]
	}
	w.mu.Unlock()
	if i < 0 {
		return 0, fmt.Errorf("wallet: no sent set %s", reservedID)
	}
	c, err := w.client(r.Mint)
	if err != nil {
		return 0, err
	}
	if w.mintBusy(r.Mint) {
		return 0, ErrBusy
	}
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return 0, err
	}
	ks, err := activeKeyset(sets)
	if err != nil {
		return 0, err
	}
	fee := inputFee(r.Proofs, sets)
	total := r.Proofs.Amount()
	if total <= fee {
		return 0, fmt.Errorf("wallet: %d sats can't cover the mint's %d sat fee", total, fee)
	}
	outs, err := newOutputs(ks, splitAmount(total-fee), RoleKeep, "")
	if err != nil {
		return 0, err
	}
	op := Op{ID: w.newID(), Kind: OpReclaim, Mint: r.Mint, Inputs: r.Proofs, Outputs: outs, Reserved: r.ID, Created: w.now().Unix()}
	if err := w.runSwap(ctx, c, op, sets); err != nil {
		return 0, err
	}
	return total - fee, nil
}

// runSwap journals op, calls /v1/swap, and applies the answer.
func (w *Wallet) runSwap(ctx context.Context, c *Client, op Op, sets map[string]Keyset) error {
	if err := w.journal(op); err != nil {
		return err
	}
	if err := w.step("swap:journaled"); err != nil {
		return err
	}
	resp, err := c.Swap(ctx, op.Inputs, blinded(op.Outputs))
	if err := w.step("swap:answered"); err != nil {
		return err
	}
	if err != nil {
		if !IsDefinite(err) {
			return fmt.Errorf("%w: %v", ErrPending, err)
		}
		return w.swapRefused(ctx, c, op, err)
	}
	proofs, err := unblindAll(op.Outputs, resp.Signatures, sets, false)
	if err != nil {
		// The mint spent our inputs but its reply is bad. Keep the op;
		// Recover asks again with NUT-09 restore.
		w.markStuck(op.ID, err.Error())
		return fmt.Errorf("%w: %v", ErrPending, err)
	}
	return w.applySwap(op, proofs)
}

// journal saves op before any mint call. For our own proofs (swap, melt) the
// inputs leave the balance now, so nothing else can pick them.
func (w *Wallet) journal(op Op) error {
	return w.commit(func(s *State) error {
		if op.Kind == OpSwap || op.Kind == OpMelt {
			s.takeProofs(op.Mint, op.Inputs)
		}
		s.Ops = append(s.Ops, op)
		return nil
	})
}

// applySwap credits signed outputs and closes the op, in one save.
func (w *Wallet) applySwap(op Op, proofs []cashu.Proof) error {
	return w.commit(func(s *State) error {
		var keep, send cashu.Proofs
		for i, p := range proofs {
			if op.Outputs[i].Role == RoleSend {
				send = append(send, p)
			} else {
				keep = append(keep, p)
			}
		}
		s.addProofs(op.Mint, keep)
		if len(send) > 0 {
			s.Reserved = append(s.Reserved, Reserved{ID: op.ID, Mint: op.Mint, Proofs: send, Memo: op.Memo, Created: op.Created})
		}
		if op.Kind == OpReclaim {
			if i := s.findReserved(op.Reserved); i >= 0 {
				s.Reserved = append(s.Reserved[:i], s.Reserved[i+1:]...)
			}
		}
		s.removeOp(op.ID)
		return nil
	})
}

// swapRefused handles a definite "no" from the mint: the swap did not happen.
// Our inputs go back, minus any the mint reports spent.
func (w *Wallet) swapRefused(ctx context.Context, c *Client, op Op, mintErr error) error {
	spent := map[string]bool{}
	if isProofSpentErr(mintErr) {
		states, err := w.inputStates(ctx, c, op.Inputs)
		if err != nil {
			// Can't tell which are spent: keep the op for Recover.
			return fmt.Errorf("%w: %v", ErrPending, err)
		}
		for secret, st := range states {
			if st != stateUnspent {
				spent[secret] = true
			}
		}
	}
	err := w.commit(func(s *State) error {
		s.removeOp(op.ID)
		switch op.Kind {
		case OpSwap:
			s.addProofs(op.Mint, unspentOnly(op.Inputs, spent))
		case OpReclaim:
			if len(spent) > 0 {
				dropReservedProofs(s, op.Reserved, spent)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(spent) > 0 {
		return fmt.Errorf("%w: %v", ErrAlreadySpent, mintErr)
	}
	return mintErr
}

func (w *Wallet) markStuck(opID, why string) {
	_ = w.commit(func(s *State) error {
		if i := s.findOp(opID); i >= 0 {
			s.Ops[i].Stuck = why
		}
		return nil
	})
}

func unspentOnly(ps cashu.Proofs, spent map[string]bool) cashu.Proofs {
	var out cashu.Proofs
	for _, p := range ps {
		if !spent[p.Secret] {
			p.Witness = ""
			out = append(out, p)
		}
	}
	return out
}

func dropReservedProofs(s *State, id string, spent map[string]bool) {
	i := s.findReserved(id)
	if i < 0 {
		return
	}
	s.Reserved[i].Proofs = unspentOnly(s.Reserved[i].Proofs, spent)
	if len(s.Reserved[i].Proofs) == 0 {
		s.Reserved = append(s.Reserved[:i], s.Reserved[i+1:]...)
	}
}
