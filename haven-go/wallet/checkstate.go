package wallet

import (
	"context"
	"fmt"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut07"
)

type proofState int

const (
	stateUnspent proofState = iota
	statePending
	stateSpent
)

// checkBatch keeps each NUT-07 request small.
const checkBatch = 100

// inputStates asks the mint for each proof's state (NUT-07), keyed by secret.
// Every proof must get an answer; a missing or unknown one is an error, so
// nothing is dropped on a partial reply.
func (w *Wallet) inputStates(ctx context.Context, c *Client, proofs cashu.Proofs) (map[string]proofState, error) {
	out := make(map[string]proofState, len(proofs))
	for start := 0; start < len(proofs); start += checkBatch {
		end := min(start+checkBatch, len(proofs))
		bySecretY := map[string]string{}
		ys := make([]string, 0, end-start)
		for _, p := range proofs[start:end] {
			y, err := proofY(p.Secret)
			if err != nil {
				return nil, err
			}
			bySecretY[y] = p.Secret
			ys = append(ys, y)
		}
		resp, err := c.CheckState(ctx, ys)
		if err != nil {
			return nil, err
		}
		for _, st := range resp.States {
			secret, ok := bySecretY[st.Y]
			if !ok {
				continue
			}
			switch st.State {
			case nut07.Unspent:
				out[secret] = stateUnspent
			case nut07.Pending:
				out[secret] = statePending
			case nut07.Spent:
				out[secret] = stateSpent
			default:
				return nil, fmt.Errorf("mint gave an unknown state for a proof")
			}
		}
	}
	for _, p := range proofs {
		if _, ok := out[p.Secret]; !ok {
			return nil, fmt.Errorf("mint did not report every proof's state")
		}
	}
	return out, nil
}

// CheckReport says what CheckState found at one mint.
type CheckReport struct {
	Mint          string `json:"mint"`
	SpentDropped  uint64 `json:"spent_dropped"`   // sats removed from the balance (spent elsewhere)
	Claimed       uint64 `json:"claimed"`         // sent (reserved) sats the receiver claimed
	PendingAtMint uint64 `json:"pending_at_mint"` // sats the mint holds as pending (kept)
}

// CheckState asks the mint (NUT-07) about every proof we hold there and drops
// the spent ones: in the balance (another device spent them) and in Reserved
// (the receiver claimed them). Proofs inside unfinished ops are left to
// Recover.
func (w *Wallet) CheckState(ctx context.Context, mint string) (CheckReport, error) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	rep := CheckReport{Mint: mint}
	c, err := w.client(mint)
	if err != nil {
		return rep, err
	}
	w.mu.Lock()
	all := append(cashu.Proofs(nil), w.state.Mints[mint].Proofs...)
	reclaiming := map[string]bool{}
	for _, op := range w.state.Ops {
		if op.Kind == OpReclaim {
			reclaiming[op.Reserved] = true
		}
	}
	for _, r := range w.state.Reserved {
		if r.Mint == mint && !reclaiming[r.ID] {
			all = append(all, r.Proofs...)
		}
	}
	w.mu.Unlock()
	if len(all) == 0 {
		return rep, nil
	}
	states, err := w.inputStates(ctx, c, all)
	if err != nil {
		return rep, err
	}
	spent := map[string]bool{}
	for secret, st := range states {
		if st == stateSpent {
			spent[secret] = true
		}
	}
	err = w.commit(func(s *State) error {
		ms := s.Mints[mint]
		if ms == nil {
			return nil
		}
		kept := cashu.Proofs{}
		for _, p := range ms.Proofs {
			switch {
			case spent[p.Secret]:
				rep.SpentDropped += p.Amount
			default:
				if states[p.Secret] == statePending {
					rep.PendingAtMint += p.Amount
				}
				kept = append(kept, p)
			}
		}
		ms.Proofs = kept
		var reserved []Reserved
		for _, r := range s.Reserved {
			if r.Mint == mint && !reclaiming[r.ID] {
				for _, p := range r.Proofs {
					if spent[p.Secret] {
						rep.Claimed += p.Amount
					}
				}
				r.Proofs = unspentOnly(r.Proofs, spent)
				if len(r.Proofs) == 0 {
					continue
				}
			}
			reserved = append(reserved, r)
		}
		s.Reserved = reserved
		return nil
	})
	return rep, err
}
