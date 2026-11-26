package wallet

// E4 (design §6b "Move to another Cashu wallet"): hand a mint's ecash to
// another wallet as one unlocked cashuB token, with no swap and no fee from
// us. The proofs leave the balance into a Reserved set, so no spend of ours
// can pick them; Rollover backs that set up as a 7375 with `exported_at`.
// CheckState drops the proofs the mint calls spent (all or part of the set:
// a partial claim) and says so in CheckReport.Claims, and TakeBack swaps the
// unclaimed rest into fresh proofs of ours, which makes the shown token
// worthless.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
)

// ErrNothingToExport means the mint holds no spendable proofs of ours.
var ErrNothingToExport = errors.New("wallet: nothing to export at this mint")

// ErrNotAToken means a Reserved set is a nutzap (locked to someone else),
// not a token we exported.
var ErrNotAToken = errors.New("wallet: this sent set is a nutzap, not a token")

// ExportedToken is one waiting token.
type ExportedToken struct {
	Reserved string `json:"reserved"` // the Reserved set id (TokenFor, TakeBack)
	Mint     string `json:"mint"`
	Amount   uint64 `json:"amount"`
	// Fee is the NUT-02 input fee the mint takes when the other wallet swaps
	// the token in (0 on most mints). Read from the keysets we already hold.
	Fee        uint64 `json:"fee"`
	Token      string `json:"token"` // cashuB…
	ExportedAt int64  `json:"exported_at"`
}

// ExportToken moves every spendable proof at mint, as it is, into a new
// Reserved set and returns it as a cashuB token. Nothing is sent to the
// mint. While an op at that mint is unfinished it returns ErrBusy (its
// inputs may come back into the balance).
func (w *Wallet) ExportToken(mint string) (ExportedToken, error) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	if _, err := w.client(mint); err != nil {
		return ExportedToken{}, err
	}
	if w.mintBusy(mint) {
		return ExportedToken{}, ErrBusy
	}
	id := w.newID()
	now := w.now().Unix()
	err := w.commit(func(s *State) error {
		ms := s.Mints[mint]
		if ms == nil || len(ms.Proofs) == 0 {
			return ErrNothingToExport
		}
		proofs := stripWitness(ms.Proofs)
		s.takeProofs(mint, ms.Proofs)
		s.Reserved = append(s.Reserved, Reserved{ID: id, Mint: mint, Proofs: proofs, Memo: "export", Created: now})
		return nil
	})
	if err != nil {
		return ExportedToken{}, err
	}
	return w.TokenFor(id)
}

// TokenFor rebuilds the cashuB token for a waiting set (the card reopened,
// the app restarted, or the set came from another device's 7375). The
// string is the same every time for the same proofs.
func (w *Wallet) TokenFor(reservedID string) (ExportedToken, error) {
	w.mu.Lock()
	i := w.state.findReserved(reservedID)
	var r Reserved
	var sets map[string]Keyset
	if i >= 0 {
		r = w.state.clone().Reserved[i]
		if ms := w.state.Mints[r.Mint]; ms != nil {
			sets = ms.Keysets
		}
	}
	myLock := w.myLockLocked()
	w.mu.Unlock()
	if i < 0 {
		return ExportedToken{}, fmt.Errorf("wallet: no sent set %s", reservedID)
	}
	if !isTokenSet(r, myLock) {
		return ExportedToken{}, ErrNotAToken
	}
	tok, err := encodeToken(r.Mint, r.Proofs)
	if err != nil {
		return ExportedToken{}, err
	}
	return ExportedToken{Reserved: r.ID, Mint: r.Mint, Amount: r.Proofs.Amount(),
		Fee: inputFee(r.Proofs, sets), Token: tok, ExportedAt: max(r.Created, 1)}, nil
}

// WaitingTokens lists the exported tokens not yet fully claimed.
func (w *Wallet) WaitingTokens() []ExportedToken {
	var out []ExportedToken
	for _, r := range w.ReservedSets() {
		if t, err := w.TokenFor(r.ID); err == nil {
			out = append(out, t)
		}
	}
	return out
}

// TakeBackResult says what TakeBack did.
type TakeBackResult struct {
	Returned uint64 `json:"returned"` // sats back in the balance (after the mint's fee)
	// Claim is set when the other wallet had already claimed some or all of
	// the token: publish Claim.History as the 7376 "sent" entry.
	Claim *Claim `json:"claim,omitempty"`
}

// TakeBack swaps a waiting token's proofs into fresh ones of ours. When the
// other wallet claimed part of it first, that part is recorded as claimed
// and the rest is swapped back. ErrAlreadySpent means it claimed all of it.
func (w *Wallet) TakeBack(ctx context.Context, reservedID string) (TakeBackResult, error) {
	var res TakeBackResult
	w.opMu.Lock()
	defer w.opMu.Unlock()
	before, groupIDs, err := w.tokenSetForTakeBack(reservedID)
	if err != nil {
		return res, err
	}
	got, err := w.reclaimLocked(ctx, reservedID)
	if errors.Is(err, ErrAlreadySpent) {
		// The mint refused the whole swap because some inputs are spent;
		// Reclaim dropped those. Swap the unspent rest, if any.
		left := w.reservedAmount(reservedID)
		if claimed := before - left; claimed > 0 {
			res.Claim = newClaim(reservedID, w.reservedMint(reservedID, ""), claimed, left == 0, groupIDs)
		}
		if left == 0 {
			return res, err
		}
		got, err = w.reclaimLocked(ctx, reservedID)
	}
	if err != nil {
		return res, err
	}
	res.Returned = got
	return res, nil
}

func (w *Wallet) tokenSetForTakeBack(id string) (uint64, []string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	i := w.state.findReserved(id)
	if i < 0 {
		return 0, nil, fmt.Errorf("wallet: no sent set %s", id)
	}
	r := w.state.Reserved[i]
	if !isTokenSet(r, w.myLockLocked()) {
		return 0, nil, ErrNotAToken
	}
	return r.Proofs.Amount(), groupEventIDs(w.state, reservedGroup(id)), nil
}

func (w *Wallet) reservedAmount(id string) uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	if i := w.state.findReserved(id); i >= 0 {
		return w.state.Reserved[i].Proofs.Amount()
	}
	return 0
}

func (w *Wallet) reservedMint(id, fallback string) string {
	w.mu.Lock()
	defer w.mu.Unlock()
	if i := w.state.findReserved(id); i >= 0 {
		return w.state.Reserved[i].Mint
	}
	return fallback
}

// Claim is a token the other wallet claimed (all of it, or part: a partial
// claim leaves the rest waiting).
type Claim struct {
	Reserved string `json:"reserved"`
	Mint     string `json:"mint"`
	Amount   uint64 `json:"amount"`
	Done     bool   `json:"done"` // nothing of the set is left waiting
	// History is the 7376 "sent" entry (HistoryTemplate). Destroyed holds
	// the set's 7375 ids as of the claim; add the replacement's id to
	// Created after the rollover if you have it.
	History HistoryEntry `json:"history"`
}

func newClaim(id, mint string, amount uint64, done bool, destroyed []string) *Claim {
	return &Claim{Reserved: id, Mint: mint, Amount: amount, Done: done,
		History: HistoryEntry{In: false, Amount: amount, Destroyed: destroyed}}
}

// groupEventIDs is the published 7375 ids of a token group.
func groupEventIDs(s *State, group string) []string {
	var ids []string
	for _, t := range s.Tokens {
		if t.Group == group {
			ids = append(ids, t.EventID)
		}
	}
	sort.Strings(ids)
	return ids
}

// isTokenSet: a Reserved set we can show as a token, i.e. not a nutzap.
// Nutzap proofs are P2PK-locked to the recipient; a plain Send or an export
// is unlocked. (A set restored from another device's 7375 is always
// unlocked: Rollover never backs up proofs locked to someone else.)
func isTokenSet(r Reserved, myLock string) bool {
	if r.Nutzap != nil || r.NutzapSent != "" {
		return false
	}
	for _, p := range r.Proofs {
		if lockedToOther(p, myLock) {
			return false
		}
		if sec, err := nut10.DeserializeSecret(p.Secret); err == nil && sec.Kind == nut10.P2PK {
			return false
		}
	}
	return true
}

// myLockLocked is our P2PK lock data ("02"+x), or "". Caller holds w.mu.
func (w *Wallet) myLockLocked() string {
	if w.state.WalletKey == "" {
		return ""
	}
	pk, err := walletPubkey(w.state.WalletKey)
	if err != nil {
		return ""
	}
	return "02" + pk
}

// encodeToken builds a NUT-00 V4 (cashuB) token, unit sat, DLEQ included
// where we have it whole (NUT-12 lets the other wallet check the proofs
// offline). Keysets and proofs are sorted so the string is stable.
func encodeToken(mint string, proofs cashu.Proofs) (string, error) {
	if len(proofs) == 0 {
		return "", ErrNothingToExport
	}
	ps := make(cashu.Proofs, len(proofs))
	for i, p := range proofs {
		p.Witness = ""
		if p.DLEQ != nil && (p.DLEQ.E == "" || p.DLEQ.S == "" || p.DLEQ.R == "") {
			p.DLEQ = nil
		}
		ps[i] = p
	}
	sort.SliceStable(ps, func(i, j int) bool {
		if ps[i].Id != ps[j].Id {
			return ps[i].Id < ps[j].Id
		}
		if ps[i].Amount != ps[j].Amount {
			return ps[i].Amount < ps[j].Amount
		}
		return ps[i].Secret < ps[j].Secret
	})
	t, err := cashu.NewTokenV4(ps, mint, cashu.Sat, true)
	if err != nil {
		return "", err
	}
	sort.Slice(t.TokenProofs, func(i, j int) bool {
		return bytes.Compare(t.TokenProofs[i].Id, t.TokenProofs[j].Id) < 0
	})
	return t.Serialize()
}
