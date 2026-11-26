package wallet

// kind 7375 token events and the rollover (§2 "Keys and storage").
//
// The Vault holds one 7375 per mint for the spendable proofs ("balance
// group") and one per unclaimed sent set ("reserved group", with E4's
// `exported_at` in its content so we keep holding those proofs back from our
// own spends). Rollover compares what the wallet holds with what it last
// published and returns the events that bring the Vault up to date.
//
// Money rules:
//   - A mint with an unfinished op (stuck or waiting on the mint) is still
//     backed up: its balance 7375 lists the proofs plus the op's inputs, so
//     the Vault never loses sats while an op can't finish.
//   - A kind-5 is only sent for an id whose replacing 7375 was committed
//     (CommitPublished), or for a group the wallet no longer holds at all.
//     So a publish that fails half way never leaves the Vault without the
//     proofs.
//   - We only ever delete ids we have seen. A device with a stale view never
//     deletes another device's newer 7375; Restore merges both by secret.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
	"github.com/nbd-wtf/go-nostr"
)

// quoteTTL is the 7374 expiration when the mint gives none (NIP-60: about
// two weeks).
const quoteTTL = 14 * 24 * 3600

// TokenContent is the plaintext of a 7375.
type TokenContent struct {
	Mint   string       `json:"mint"`
	Unit   string       `json:"unit,omitempty"`
	Proofs cashu.Proofs `json:"proofs"`
	Del    []string     `json:"del,omitempty"`
	// ExportedAt (E4) marks proofs handed out as a token and not yet
	// claimed. Other NIP-60 wallets ignore it; we keep them out of the
	// spendable balance.
	ExportedAt int64 `json:"exported_at,omitempty"`
}

func balanceGroup(mint string) string { return "b|" + mint }
func reservedGroup(id string) string  { return "r|" + id }

func tokenDigest(proofs cashu.Proofs, exportedAt int64) string {
	ss := make([]string, len(proofs))
	for i, p := range proofs {
		ss[i] = p.Secret
	}
	sort.Strings(ss)
	h := sha256.Sum256([]byte(strings.Join(ss, "\n") + fmt.Sprintf("|%d", exportedAt)))
	return hex.EncodeToString(h[:])
}

// lockedToOther reports a P2PK proof locked to a key that is not our wallet
// key (a nutzap we sent): it is the recipient's money, not ours to store.
func lockedToOther(p cashu.Proof, myLock string) bool {
	sec, err := nut10.DeserializeSecret(p.Secret)
	if err != nil || sec.Kind != nut10.P2PK {
		return false
	}
	return myLock == "" || !strings.EqualFold(sec.Data.Data, myLock)
}

func stripWitness(ps cashu.Proofs) cashu.Proofs {
	out := make(cashu.Proofs, len(ps))
	for i, p := range ps {
		p.Witness = ""
		out[i] = p
	}
	return out
}

type tokenGroupNow struct {
	mint       string
	proofs     cashu.Proofs
	exportedAt int64
}

// RolloverPlan is what to publish, in order. Publish each event, then call
// CommitPublished with its id before the next; stop at the first failure.
// Call Rollover again until it returns no events (kind-5s for replaced
// 7375s come one round after their replacement is committed).
type RolloverPlan struct {
	Events []Template `json:"events"`
	// Busy lists mints with an unfinished op. Their balance 7375 holds the
	// proofs plus the op's inputs until the op is settled.
	Busy []string `json:"busy,omitempty"`
	// WalletHold, when set, is why no 17375 was planned (State.WalletHold).
	WalletHold string `json:"wallet_hold,omitempty"`
}

// Rollover returns the events that bring the Vault copy up to date with the
// wallet: the 17375 when the key or mints changed, one 7375 per changed
// group, 7374s for new receive quotes, and kind-5s for what is gone.
func (w *Wallet) Rollover() (RolloverPlan, error) {
	w.mu.Lock()
	s := w.state.clone()
	w.mu.Unlock()
	now := w.now().Unix()
	var plan RolloverPlan

	mints := make([]string, 0, len(s.Mints))
	for u := range s.Mints {
		mints = append(mints, u)
	}
	sort.Strings(mints)
	plan.WalletHold = s.WalletHold
	if s.WalletKey != "" && s.WalletHold == "" && walletDigest(s.WalletKey, mints) != s.WalletDigest {
		plan.Events = append(plan.Events, walletTemplate(now, s.WalletKey, mints))
	}

	busy := map[string]bool{}
	inFlight := map[string]cashu.Proofs{}
	for _, op := range s.Ops {
		busy[op.Mint] = true
		if op.Kind != OpReclaim { // reclaim inputs are still in their Reserved set
			inFlight[op.Mint] = append(inFlight[op.Mint], stripWitness(op.Inputs)...)
		}
	}
	for u := range busy {
		plan.Busy = append(plan.Busy, u)
	}
	sort.Strings(plan.Busy)

	myLock := ""
	if s.WalletKey != "" {
		if pk, err := walletPubkey(s.WalletKey); err == nil {
			myLock = "02" + pk
		}
	}
	cur := map[string]tokenGroupNow{}
	for u, ms := range s.Mints {
		// An unfinished op's inputs stay in the backup until the op is
		// settled: they may still be ours (the mint never got the call), and
		// a restore's checkstate drops the ones that were spent.
		proofs := append(cashu.Proofs(nil), ms.Proofs...)
		have := map[string]bool{}
		for _, p := range proofs {
			have[p.Secret] = true
		}
		for _, p := range inFlight[u] {
			if !have[p.Secret] && !lockedToOther(p, myLock) {
				have[p.Secret] = true
				proofs = append(proofs, p)
			}
		}
		if len(proofs) > 0 {
			cur[balanceGroup(u)] = tokenGroupNow{mint: u, proofs: proofs}
		}
	}
	for _, r := range s.Reserved {
		var keep cashu.Proofs
		for _, p := range r.Proofs {
			if !lockedToOther(p, myLock) {
				keep = append(keep, p)
			}
		}
		if len(keep) > 0 {
			cur[reservedGroup(r.ID)] = tokenGroupNow{mint: r.Mint, proofs: keep, exportedAt: max(r.Created, 1)}
		}
	}
	pubs := map[string][]PublishedToken{}
	for _, t := range s.Tokens {
		pubs[t.Group] = append(pubs[t.Group], t)
	}
	groups := map[string]bool{}
	for g := range cur {
		groups[g] = true
	}
	for g := range pubs {
		groups[g] = true
	}
	keys := make([]string, 0, len(groups))
	for g := range groups {
		keys = append(keys, g)
	}
	sort.Strings(keys)

	var tokenDeletes []string
	for _, g := range keys {
		c, have := cur[g]
		old := pubs[g]
		var oldIDs []string
		for _, t := range old {
			oldIDs = append(oldIDs, t.EventID)
		}
		if !have {
			tokenDeletes = append(tokenDeletes, oldIDs...)
			continue
		}
		d := tokenDigest(c.proofs, c.exportedAt)
		if len(old) == 1 && old[0].Digest == d {
			continue
		}
		content := TokenContent{Mint: c.mint, Unit: cashu.Sat.String(), Proofs: stripWitness(c.proofs),
			Del: oldIDs, ExportedAt: c.exportedAt}
		b, err := json.Marshal(content)
		if err != nil {
			return RolloverPlan{}, err
		}
		plan.Events = append(plan.Events, Template{Kind: KindToken, CreatedAt: now, Tags: nostr.Tags{},
			Content: string(b), Encrypt: true, Where: WherePrivate,
			Meta: &TemplateMeta{Group: g, Mint: c.mint, Digest: d, Replaces: oldIDs}})
	}

	quoteIDs := map[string]bool{}
	for _, q := range s.MintQuotes {
		quoteIDs[q.ID] = true
		if _, ok := s.QuoteEvents[q.ID]; ok {
			continue
		}
		plan.Events = append(plan.Events, quoteTemplate(now, q))
	}
	var quoteDeletes []string
	for q, id := range s.QuoteEvents {
		if !quoteIDs[q] {
			quoteDeletes = append(quoteDeletes, id)
		}
	}
	sort.Strings(quoteDeletes)

	tokenDeletes = append(tokenDeletes, s.PendingDeletes...)
	if len(tokenDeletes) > 0 {
		plan.Events = append(plan.Events, deletionTemplate(now, KindToken, dedupe(tokenDeletes)))
	}
	if len(quoteDeletes) > 0 {
		plan.Events = append(plan.Events, deletionTemplate(now, KindQuote, quoteDeletes))
	}
	return plan, nil
}

func dedupe(ids []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

func quoteTemplate(now int64, q MintQuote) Template {
	exp := int64(q.Expiry)
	if exp <= now {
		exp = now + quoteTTL
	}
	tags := nostr.Tags{{"mint", q.Mint}, {"expiration", fmt.Sprint(exp)}}
	return Template{Kind: KindQuote, CreatedAt: now, Tags: tags, Content: q.ID, Encrypt: true,
		Where: WherePrivate, Meta: &TemplateMeta{Mint: q.Mint, Quote: q.ID}}
}

// CommitPublished records that t (from Rollover) was published as eventID.
func (w *Wallet) CommitPublished(t Template, eventID string) error {
	if len(eventID) != 64 {
		return fmt.Errorf("wallet: event id must be 64 hex characters")
	}
	if _, err := hex.DecodeString(eventID); err != nil {
		return fmt.Errorf("wallet: event id must be hex")
	}
	if t.Meta == nil {
		return fmt.Errorf("wallet: template has no meta; pass it back as Rollover gave it")
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	return w.commit(func(s *State) error {
		switch t.Kind {
		case KindWallet:
			s.WalletDigest = t.Meta.Digest
		case KindToken:
			gone := idSet(t.Meta.Replaces)
			s.Tokens = keepTokens(s.Tokens, gone)
			s.Tokens = append(s.Tokens, PublishedToken{EventID: eventID, Mint: t.Meta.Mint, Group: t.Meta.Group, Digest: t.Meta.Digest})
			s.PendingDeletes = dedupe(append(s.PendingDeletes, t.Meta.Replaces...))
		case KindNutzap:
			return commitNutzap(s, t.Meta.Reserved, eventID)
		case KindQuote:
			if s.QuoteEvents == nil {
				s.QuoteEvents = map[string]string{}
			}
			s.QuoteEvents[t.Meta.Quote] = eventID
		case KindDeletion:
			gone := idSet(t.Meta.Deletes)
			s.Tokens = keepTokens(s.Tokens, gone)
			s.PendingDeletes = keepIDs(s.PendingDeletes, gone)
			for q, id := range s.QuoteEvents {
				if gone[id] {
					delete(s.QuoteEvents, q)
				}
			}
		default:
			return fmt.Errorf("wallet: kind %d is not a rollover event", t.Kind)
		}
		return nil
	})
}

func idSet(ids []string) map[string]bool {
	m := make(map[string]bool, len(ids))
	for _, id := range ids {
		m[id] = true
	}
	return m
}

func keepTokens(ts []PublishedToken, gone map[string]bool) []PublishedToken {
	var out []PublishedToken
	for _, t := range ts {
		if !gone[t.EventID] {
			out = append(out, t)
		}
	}
	return out
}

func keepIDs(ids []string, gone map[string]bool) []string {
	var out []string
	for _, id := range ids {
		if !gone[id] {
			out = append(out, id)
		}
	}
	return out
}

// ParseToken reads a 7375. author is the account pubkey (hex).
func ParseToken(oe OwnEvent, author string) (TokenContent, error) {
	if err := checkSigned(oe.Event, KindToken, author); err != nil {
		return TokenContent{}, err
	}
	var c TokenContent
	if err := json.Unmarshal([]byte(oe.Plaintext), &c); err != nil {
		return TokenContent{}, fmt.Errorf("%w: 7375 content unreadable", ErrBadEvent)
	}
	u, err := NormalizeMintURL(c.Mint)
	if err != nil {
		return TokenContent{}, fmt.Errorf("%w: 7375 mint: %v", ErrBadEvent, err)
	}
	c.Mint = u
	if c.Unit != "" && c.Unit != cashu.Sat.String() {
		return TokenContent{}, fmt.Errorf("%w: 7375 unit %q (only sat)", ErrBadEvent, c.Unit)
	}
	for _, p := range c.Proofs {
		if p.Secret == "" || p.C == "" || p.Amount == 0 {
			return TokenContent{}, fmt.Errorf("%w: 7375 has an incomplete proof", ErrBadEvent)
		}
	}
	return c, nil
}

// ParseQuote reads a 7374: the plaintext is the quote id, the mint and the
// expiration are public tags.
func ParseQuote(oe OwnEvent, author string) (mint, quote string, expiration int64, err error) {
	if err := checkSigned(oe.Event, KindQuote, author); err != nil {
		return "", "", 0, err
	}
	quote = strings.TrimSpace(oe.Plaintext)
	if quote == "" {
		return "", "", 0, fmt.Errorf("%w: 7374 has no quote id", ErrBadEvent)
	}
	for _, t := range oe.Event.Tags {
		if len(t) < 2 {
			continue
		}
		switch t[0] {
		case "mint":
			mint, err = NormalizeMintURL(t[1])
			if err != nil {
				return "", "", 0, fmt.Errorf("%w: 7374 mint: %v", ErrBadEvent, err)
			}
		case "expiration":
			fmt.Sscan(t[1], &expiration)
		}
	}
	if mint == "" {
		return "", "", 0, fmt.Errorf("%w: 7374 has no mint", ErrBadEvent)
	}
	return mint, quote, expiration, nil
}
