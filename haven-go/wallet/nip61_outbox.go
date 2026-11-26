package wallet

// Sending a nutzap safely (Tron review of PR 2560, must-fixes 1 and 2).
//
// The swap that locks sats to the recipient can't be undone, so two things
// protect them until the 9321 is out:
//   - Every nutzap output carries a NUT-11 refund tag to our own wallet key
//     with a locktime (NutzapRefundAfter). If the 9321 can't be built (the
//     mint sent no DLEQ) or never gets out, Reclaim takes the sats back once
//     the locktime passes. Before it, only the recipient can spend them.
//   - The NutzapRequest is journaled with the swap and kept on the Reserved
//     set until CommitPublished sees the 9321, so after a crash
//     UnsentNutzaps lists it and NutzapTemplateFor rebuilds the same event.

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
	"github.com/elnosh/gonuts/cashu/nuts/nut11"
)

// NutzapRefundAfter is how long a sent nutzap is the recipient's alone.
// After it our wallet key may also spend it (NUT-11 refund).
const NutzapRefundAfter int64 = 7 * 24 * 3600

var (
	// ErrNutzapNoDLEQ means the mint signed the nutzap without a DLEQ, so
	// the recipient can't check it. The sats sit in Reserved with a refund
	// to us; Reclaim works after RefundAfter.
	ErrNutzapNoDLEQ = errors.New("wallet: mint gave no DLEQ; the nutzap can't be checked (the sats come back after the refund time)")
	// ErrRefundNotYet means a sent nutzap is still the recipient's alone.
	ErrRefundNotYet = errors.New("wallet: these sats can only be taken back after the refund time")
	// ErrNoNutzap means the Reserved set is not an unsent nutzap.
	ErrNoNutzap = errors.New("wallet: no unsent nutzap with that id")
)

// SendNutzap swaps amount sats into proofs locked to the recipient's 10019
// key (refund to our wallet key after NutzapRefundAfter), at the first mint
// in their list where we hold enough, and returns the 9321 to sign and
// publish to their 10019 relays. Publish it, then CommitPublished(t, id). If
// the app stops before that, UnsentNutzaps lists it and NutzapTemplateFor
// rebuilds it. On ErrNutzapNoDLEQ the Reserved set is returned too: no 9321
// can be built and the sats come back by Reclaim after RefundAfter.
func (w *Wallet) SendNutzap(ctx context.Context, req NutzapRequest) (Template, Reserved, error) {
	if req.Info.Pubkey == "" || len(req.Info.Mints) == 0 {
		return Template{}, Reserved{}, ErrNoNutzaps
	}
	if len(req.Recipient) != 64 {
		return Template{}, Reserved{}, fmt.Errorf("wallet: recipient must be a hex pubkey")
	}
	me := w.WalletPubkey()
	if me == "" {
		return Template{}, Reserved{}, fmt.Errorf("wallet: no wallet key yet (needed for the nutzap refund)")
	}
	mine := map[string]bool{}
	for _, m := range w.Mints() {
		mine[m] = true
	}
	var lastErr error = ErrNoSharedMint
	for _, m := range req.Info.Mints {
		if !mine[m] || !w.mintSupportsDLEQ(m) {
			continue
		}
		lockTags := [][]string{
			{"locktime", strconv.FormatInt(w.now().Unix()+NutzapRefundAfter, 10)},
			{"refund", "02" + me},
		}
		nz := req
		r, err := w.send(ctx, m, req.Amount, req.Info.Pubkey, lockTags, "nutzap", &nz)
		if errors.Is(err, ErrNotEnough) {
			lastErr = err
			continue
		}
		if err != nil {
			return Template{}, Reserved{}, err
		}
		t, err := nutzapTemplate(w.now().Unix(), req, r)
		if err != nil {
			w.dropNutzapRequest(r.ID) // nothing to rebuild; Reclaim after RefundAfter
		}
		return t, r, err
	}
	return Template{}, Reserved{}, lastErr
}

// UnsentNutzaps lists Reserved sets whose 9321 is not committed as
// published. Call at start-up and publish each NutzapTemplateFor.
func (w *Wallet) UnsentNutzaps() []Reserved {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out []Reserved
	for _, r := range w.state.clone().Reserved {
		if r.Nutzap != nil && r.NutzapSent == "" {
			out = append(out, r)
		}
	}
	return out
}

// NutzapTemplateFor rebuilds the 9321 for an unsent nutzap.
func (w *Wallet) NutzapTemplateFor(reservedID string) (Template, error) {
	w.mu.Lock()
	i := w.state.findReserved(reservedID)
	var r Reserved
	if i >= 0 {
		r = w.state.clone().Reserved[i]
	}
	w.mu.Unlock()
	if i < 0 || r.Nutzap == nil || r.NutzapSent != "" {
		return Template{}, ErrNoNutzap
	}
	return nutzapTemplate(w.now().Unix(), *r.Nutzap, r)
}

func (w *Wallet) dropNutzapRequest(id string) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	_ = w.commit(func(s *State) error {
		if i := s.findReserved(id); i >= 0 {
			s.Reserved[i].Nutzap = nil
		}
		return nil
	})
}

// commitNutzap records a published 9321 (called from CommitPublished).
func commitNutzap(s *State, reservedID, eventID string) error {
	i := s.findReserved(reservedID)
	if i < 0 {
		return nil // already claimed or reclaimed
	}
	s.Reserved[i].NutzapSent = eventID
	s.Reserved[i].Nutzap = nil
	return nil
}

// refundAfter is the latest NUT-11 locktime among P2PK proofs that carry a
// refund tag, or 0.
func refundAfter(ps cashu.Proofs) int64 {
	var at int64
	for _, p := range ps {
		sec, err := nut10.DeserializeSecret(p.Secret)
		if err != nil || sec.Kind != nut10.P2PK {
			continue
		}
		tags, err := nut11.ParseP2PKTags(sec.Data.Tags)
		if err != nil || len(tags.Refund) == 0 {
			continue
		}
		at = max(at, tags.Locktime)
	}
	return at
}

// reclaimInputs signs a Reserved set's P2PK proofs with our wallet key when
// they are a nutzap whose refund time has passed. Unlocked proofs pass
// through untouched.
func (w *Wallet) reclaimInputs(r Reserved) (cashu.Proofs, error) {
	locked := false
	for _, p := range r.Proofs {
		if sec, err := nut10.DeserializeSecret(p.Secret); err == nil && sec.Kind == nut10.P2PK {
			locked = true
		}
	}
	if !locked {
		return r.Proofs, nil
	}
	at := refundAfter(r.Proofs)
	if at == 0 {
		return nil, fmt.Errorf("wallet: these proofs are locked to someone else and have no refund")
	}
	if w.now().Unix() < at {
		return nil, ErrRefundNotYet
	}
	key, err := w.signKey()
	if err != nil {
		return nil, err
	}
	in := make(cashu.Proofs, len(r.Proofs))
	copy(in, r.Proofs)
	return nut11.AddSignatureToInputs(in, key)
}
