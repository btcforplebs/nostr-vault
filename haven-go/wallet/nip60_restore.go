package wallet

// Restore on login (§2 "Restore on login"): the app reads 17375, 7375, 7374
// and the kind-5s with #k 7375/7374 from the owner's Vault /private relays,
// decrypts them with the active signer, and hands them here. Restore merges
// them into the local wallet by proof secret, then asks each mint (NUT-07)
// which proofs are spent.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut04"
	"github.com/nbd-wtf/go-nostr"
)

// RestoreInput is everything read from the Vault for one account.
type RestoreInput struct {
	Account   string        `json:"account"` // account pubkey hex
	Wallet    *OwnEvent     `json:"wallet,omitempty"`
	Tokens    []OwnEvent    `json:"tokens,omitempty"`
	Quotes    []OwnEvent    `json:"quotes,omitempty"`
	Deletions []nostr.Event `json:"deletions,omitempty"`
}

// RestoreReport says what Restore did.
type RestoreReport struct {
	WalletFound bool                   `json:"wallet_found"`
	Mints       []string               `json:"mints"`
	Added       uint64                 `json:"added"`   // sats merged in, before checkstate
	Deleted     int                    `json:"deleted"` // token/quote events skipped as deleted or replaced
	Bad         []string               `json:"bad,omitempty"`
	Quotes      int                    `json:"quotes"` // receive quotes brought back
	Check       map[string]CheckReport `json:"check,omitempty"`
	CheckErrors map[string]string      `json:"check_errors,omitempty"`
}

type pendingQuote struct {
	mint, quote, event string
	expiration         int64
}

// Restore merges the Vault copy into the wallet. A 17375 that does not parse
// is an error and nothing changes: "wallet found but can't be opened" is its
// own state, never "no wallet". So is a different wallet key
// (ErrKeyConflict). Bad 7375/7374 events are skipped and listed in Bad.
func (w *Wallet) Restore(ctx context.Context, in RestoreInput) (RestoreReport, error) {
	rep := RestoreReport{Check: map[string]CheckReport{}, CheckErrors: map[string]string{}}
	var info *WalletInfo
	if in.Wallet != nil {
		wi, err := ParseWallet(*in.Wallet, in.Account)
		if err != nil {
			w.holdWallet("the Vault's wallet event can't be opened")
			return rep, fmt.Errorf("wallet found but can't be opened: %w", err)
		}
		info = &wi
		rep.WalletFound = true
	}

	deleted := deletedIDs(in.Deletions, in.Account)
	type tok struct {
		id string
		c  TokenContent
	}
	var toks []tok
	for _, oe := range in.Tokens {
		c, err := ParseToken(oe, in.Account)
		if err != nil {
			rep.Bad = append(rep.Bad, oe.Event.ID)
			continue
		}
		toks = append(toks, tok{oe.Event.ID, c})
		for _, id := range c.Del {
			deleted[id] = true
		}
	}
	var quotes []pendingQuote
	for _, oe := range in.Quotes {
		mint, q, exp, err := ParseQuote(oe, in.Account)
		if err != nil {
			rep.Bad = append(rep.Bad, oe.Event.ID)
			continue
		}
		quotes = append(quotes, pendingQuote{mint, q, oe.Event.ID, exp})
	}

	w.opMu.Lock()
	var fetch []pendingQuote
	err := w.commit(func(s *State) error {
		if info != nil {
			if err := applyWalletInfo(s, *info); err != nil {
				return err
			}
			s.WalletHold = "" // the Vault's 17375 opened and holds our key
		}
		known := localSecrets(s)
		indexed := map[string]bool{}
		for _, t := range s.Tokens {
			indexed[t.EventID] = true
		}
		// Ids another device replaced or deleted leave our index.
		s.Tokens = keepTokens(s.Tokens, deleted)
		s.PendingDeletes = keepIDs(s.PendingDeletes, deleted)
		rep.Added = 0
		for _, t := range toks {
			if deleted[t.id] {
				rep.Deleted++
				continue
			}
			group := balanceGroup(t.c.Mint)
			if t.c.ExportedAt > 0 {
				group = reservedGroup(restoreReservedID(s, t.id, t.c))
			}
			if !indexed[t.id] {
				s.Tokens = append(s.Tokens, PublishedToken{EventID: t.id, Mint: t.c.Mint, Group: group,
					Digest: tokenDigest(t.c.Proofs, t.c.ExportedAt)})
				indexed[t.id] = true
			}
			var fresh, moved cashu.Proofs
			for _, p := range stripWitness(t.c.Proofs) {
				if !known[p.Secret] {
					known[p.Secret] = true
					fresh = append(fresh, p)
				} else if t.c.ExportedAt > 0 && inBalance(s, t.c.Mint, p.Secret) {
					// Another device exported proofs our stale copy still
					// counts as balance: the export wins, so no spend of ours
					// can pick them and Rollover keeps its 7375.
					moved = append(moved, p)
				}
			}
			if len(moved) > 0 {
				s.takeProofs(t.c.Mint, moved)
				addReserved(s, strings.TrimPrefix(group, "r|"), t.c, moved)
			}
			if len(fresh) == 0 {
				if s.Mints[t.c.Mint] == nil {
					s.Mints[t.c.Mint] = &MintState{URL: t.c.Mint}
				}
				continue
			}
			rep.Added += fresh.Amount()
			if t.c.ExportedAt > 0 {
				addReserved(s, strings.TrimPrefix(group, "r|"), t.c, fresh)
				if s.Mints[t.c.Mint] == nil {
					s.Mints[t.c.Mint] = &MintState{URL: t.c.Mint}
				}
			} else {
				s.addProofs(t.c.Mint, fresh)
			}
		}
		now := w.now().Unix()
		for _, q := range quotes {
			if deleted[q.event] {
				rep.Deleted++
				continue
			}
			if q.expiration > 0 && q.expiration <= now {
				continue
			}
			if s.QuoteEvents == nil {
				s.QuoteEvents = map[string]string{}
			}
			local := false
			for _, mq := range s.MintQuotes {
				if mq.ID == q.quote {
					local = true
				}
			}
			if local {
				s.QuoteEvents[q.quote] = q.event
			} else if _, ok := s.QuoteEvents[q.quote]; !ok {
				fetch = append(fetch, q)
			}
			if s.Mints[q.mint] == nil {
				s.Mints[q.mint] = &MintState{URL: q.mint}
			}
		}
		return nil
	})
	w.opMu.Unlock()
	if errors.Is(err, ErrKeyConflict) {
		w.holdWallet("the Vault holds a different wallet key")
	}
	if err != nil {
		return rep, err
	}

	for _, q := range fetch {
		if err := w.restoreQuote(ctx, q); err != nil {
			rep.CheckErrors["quote:"+q.quote] = err.Error()
			continue
		}
		rep.Quotes++
	}
	rep.Mints = w.Mints()
	// Check every mint we hold proofs at, not only the ones the Vault added
	// to: a device with a stale copy learns here which proofs another
	// device already spent.
	for _, m := range w.mintsHolding() {
		cr, err := w.CheckState(ctx, m)
		if err != nil {
			rep.CheckErrors[m] = err.Error()
			continue
		}
		rep.Check[m] = cr
	}
	return rep, nil
}

// localSecrets is every proof secret the wallet already knows about: the
// balance, sent sets, and the inputs and outputs of unfinished ops. Restore
// never adds one of these again (an op's inputs must not go back into the
// balance while the mint's answer is unknown).
func localSecrets(s *State) map[string]bool {
	known := map[string]bool{}
	for _, ms := range s.Mints {
		for _, p := range ms.Proofs {
			known[p.Secret] = true
		}
	}
	for _, r := range s.Reserved {
		for _, p := range r.Proofs {
			known[p.Secret] = true
		}
	}
	for _, op := range s.Ops {
		for _, p := range op.Inputs {
			known[p.Secret] = true
		}
		for _, o := range op.Outputs {
			known[o.Secret] = true
		}
	}
	return known
}

// inBalance reports a proof (by secret) in mint's spendable balance.
func inBalance(s *State, mint, secret string) bool {
	ms := s.Mints[mint]
	if ms == nil {
		return false
	}
	for _, p := range ms.Proofs {
		if p.Secret == secret {
			return true
		}
	}
	return false
}

// restoreReservedID picks the Reserved id for an exported 7375: the local
// set that already holds one of its proofs, else one named after the event.
func restoreReservedID(s *State, eventID string, c TokenContent) string {
	in := map[string]bool{}
	for _, p := range c.Proofs {
		in[p.Secret] = true
	}
	for _, r := range s.Reserved {
		for _, p := range r.Proofs {
			if in[p.Secret] {
				return r.ID
			}
		}
	}
	return "ev:" + eventID
}

func addReserved(s *State, id string, c TokenContent, proofs cashu.Proofs) {
	if i := s.findReserved(id); i >= 0 {
		s.Reserved[i].Proofs = append(s.Reserved[i].Proofs, proofs...)
		return
	}
	s.Reserved = append(s.Reserved, Reserved{ID: id, Mint: c.Mint, Proofs: proofs, Memo: "restored", Created: c.ExportedAt})
}

// quoteStatus is a NUT-04 quote reply including `amount` (current NUT-04;
// gonuts v0.4.2's struct has no amount field).
type quoteStatus struct {
	Quote   string `json:"quote"`
	Request string `json:"request"`
	State   string `json:"state"`
	Expiry  uint64 `json:"expiry"`
	Amount  uint64 `json:"amount"`
}

// restoreQuote brings back a receive quote another device made. The 7374
// carries only the quote id, so the amount comes from the mint (or the bolt11
// amount). An issued quote is recorded as done so Rollover deletes its 7374.
func (w *Wallet) restoreQuote(ctx context.Context, q pendingQuote) error {
	c, err := w.client(q.mint)
	if err != nil {
		return err
	}
	var st quoteStatus
	if err := c.do(ctx, http.MethodGet, "/v1/mint/quote/bolt11/"+url.PathEscape(q.quote), nil, &st); err != nil {
		return err
	}
	amount := st.Amount
	if amount == 0 {
		amount = bolt11Sats(st.Request)
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	return w.commit(func(s *State) error {
		if s.QuoteEvents == nil {
			s.QuoteEvents = map[string]string{}
		}
		for _, mq := range s.MintQuotes {
			if mq.ID == q.quote {
				s.QuoteEvents[q.quote] = q.event
				return nil
			}
		}
		if nut04.StringToState(st.State) == nut04.Issued {
			s.QuoteEvents[q.quote] = q.event // claimed elsewhere; Rollover deletes the 7374
			return nil
		}
		if amount == 0 {
			return fmt.Errorf("wallet: mint did not say the amount of quote %s", q.quote)
		}
		s.MintQuotes = append(s.MintQuotes, MintQuote{ID: q.quote, Mint: q.mint, Amount: amount,
			Request: st.Request, Expiry: st.Expiry, Created: w.now().Unix()})
		s.QuoteEvents[q.quote] = q.event
		return nil
	})
}

// bolt11Sats reads the amount from a bolt11 invoice's human-readable part
// (lnbc<amount><multiplier>1...). 0 when there is none or it is not whole sats.
func bolt11Sats(inv string) uint64 {
	inv = strings.ToLower(strings.TrimPrefix(strings.ToLower(inv), "lightning:"))
	sep := strings.LastIndexByte(inv, '1')
	if sep < 0 {
		return 0
	}
	hrp := inv[:sep]
	for _, pre := range []string{"lnbcrt", "lntbs", "lntb", "lnbc", "lnsb"} {
		if strings.HasPrefix(hrp, pre) {
			hrp = hrp[len(pre):]
			break
		}
	}
	if hrp == "" {
		return 0
	}
	mult := hrp[len(hrp)-1]
	num := hrp
	// msat per unit of the amount.
	var msat uint64 = 100_000_000_000 // whole bitcoin
	switch mult {
	case 'm':
		msat, num = 100_000_000, hrp[:len(hrp)-1]
	case 'u':
		msat, num = 100_000, hrp[:len(hrp)-1]
	case 'n':
		msat, num = 100, hrp[:len(hrp)-1]
	case 'p':
		n, err := strconv.ParseUint(hrp[:len(hrp)-1], 10, 64)
		if err != nil || n%10_000 != 0 {
			return 0
		}
		return n / 10_000
	}
	n, err := strconv.ParseUint(num, 10, 64)
	if err != nil || n == 0 {
		return 0
	}
	total := n * msat
	if total/msat != n || total%1000 != 0 {
		return 0
	}
	return total / 1000
}

// mintsHolding lists mints where the wallet holds spendable or sent proofs.
func (w *Wallet) mintsHolding() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	has := map[string]bool{}
	for u, ms := range w.state.Mints {
		if len(ms.Proofs) > 0 {
			has[u] = true
		}
	}
	for _, r := range w.state.Reserved {
		has[r.Mint] = true
	}
	out := make([]string, 0, len(has))
	for u := range has {
		out = append(out, u)
	}
	sort.Strings(out)
	return out
}

// holdWallet records why Rollover must not publish our 17375 (see
// State.WalletHold). Best effort: if the save fails, Restore still returned
// the error and the app shows it.
func (w *Wallet) holdWallet(why string) {
	w.opMu.Lock()
	defer w.opMu.Unlock()
	_ = w.commit(func(s *State) error {
		s.WalletHold = why
		return nil
	})
}
