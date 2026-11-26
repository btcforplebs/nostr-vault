package wallet

// NIP-61 nutzaps: kind 10019 (where and how to nutzap someone, public) and
// kind 9321 (the nutzap: P2PK-locked proofs, public).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
	"github.com/elnosh/gonuts/cashu/nuts/nut11"
	"github.com/elnosh/gonuts/cashu/nuts/nut12"
	"github.com/nbd-wtf/go-nostr"
)

var (
	// ErrNoNutzaps means the recipient's 10019 has no mint or no pubkey.
	ErrNoNutzaps = errors.New("wallet: this person doesn't take nutzaps")
	// ErrNoSharedMint means we hold nothing at any mint in their 10019.
	ErrNoSharedMint = errors.New("wallet: no balance at a mint they take")
	// ErrBadNutzap means a 9321 failed a check; it is not counted or claimed.
	ErrBadNutzap = errors.New("wallet: nutzap is not valid")
)

// NutzapInfo is a parsed 10019.
type NutzapInfo struct {
	Pubkey string   `json:"pubkey"` // P2PK lock key, x-only hex
	Mints  []string `json:"mints"`
	Relays []string `json:"relays"`
}

// NutzapInfoTemplate builds our 10019 (public): our mints, the wallet's
// public key and the relays where nutzaps to us should go.
func (w *Wallet) NutzapInfoTemplate(relays []string) (Template, error) {
	pk := w.WalletPubkey()
	if pk == "" {
		return Template{}, fmt.Errorf("wallet: no wallet key yet")
	}
	mints := w.Mints()
	if len(mints) == 0 {
		return Template{}, fmt.Errorf("wallet: add a mint first")
	}
	tags := nostr.Tags{}
	for _, r := range relays {
		tags = append(tags, nostr.Tag{"relay", r})
	}
	for _, m := range mints {
		tags = append(tags, nostr.Tag{"mint", m, "sat"})
	}
	tags = append(tags, nostr.Tag{"pubkey", pk})
	return Template{Kind: KindNutzapInfo, CreatedAt: w.now().Unix(), Tags: tags, Where: WherePublic}, nil
}

// ParseNutzapInfo reads someone's 10019 (author = their pubkey). Mints that
// list units without "sat" are skipped.
func ParseNutzapInfo(ev nostr.Event, author string) (NutzapInfo, error) {
	if err := checkSigned(ev, KindNutzapInfo, author); err != nil {
		return NutzapInfo{}, err
	}
	var info NutzapInfo
	seen := map[string]bool{}
	for _, t := range ev.Tags {
		if len(t) < 2 {
			continue
		}
		switch t[0] {
		case "mint":
			if len(t) > 2 && !contains(t[2:], "sat") {
				continue
			}
			u, err := NormalizeMintURL(t[1])
			if err != nil || seen[u] {
				continue
			}
			seen[u] = true
			info.Mints = append(info.Mints, u)
		case "relay":
			info.Relays = append(info.Relays, t[1])
		case "pubkey":
			if k, err := normalizeLockKey(t[1]); err == nil && info.Pubkey == "" {
				info.Pubkey = k[2:] // x-only
				if k[:2] != "02" {
					info.Pubkey = "" // NIP-61 locks to "02"+x; an odd key can't be used
				}
			}
		}
	}
	if len(info.Mints) == 0 || info.Pubkey == "" {
		return info, ErrNoNutzaps
	}
	return info, nil
}

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// NutzapRequest is one nutzap to send.
type NutzapRequest struct {
	Recipient string     `json:"recipient"` // their account pubkey hex
	Info      NutzapInfo `json:"info"`      // their 10019
	Amount    uint64     `json:"amount"`
	Comment   string     `json:"comment,omitempty"`
	EventID   string     `json:"event_id,omitempty"` // the note zapped
	Relay     string     `json:"relay,omitempty"`    // relay hint for the note
	EventKind int        `json:"event_kind,omitempty"`
}

// SendNutzap swaps amount sats into proofs locked to the recipient's 10019
// key, at the first mint in their list where we hold enough, and returns the
// 9321 to sign and publish to their 10019 relays. The locked proofs stay in
// Reserved until CheckState sees them claimed. If the 9321 is never
// published the sats are gone to us (they are locked to the recipient), so
// the app must publish it, and retry on failure, before anything else.
func (w *Wallet) SendNutzap(ctx context.Context, req NutzapRequest) (Template, Reserved, error) {
	if req.Info.Pubkey == "" || len(req.Info.Mints) == 0 {
		return Template{}, Reserved{}, ErrNoNutzaps
	}
	if len(req.Recipient) != 64 {
		return Template{}, Reserved{}, fmt.Errorf("wallet: recipient must be a hex pubkey")
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
		r, err := w.Send(ctx, m, req.Amount, req.Info.Pubkey, "nutzap")
		if errors.Is(err, ErrNotEnough) {
			lastErr = err
			continue
		}
		if err != nil {
			return Template{}, Reserved{}, err
		}
		t, err := nutzapTemplate(w.now().Unix(), req, r)
		return t, r, err
	}
	return Template{}, Reserved{}, lastErr
}

// mintSupportsDLEQ is a cheap pre-check: proofs we hold there carry DLEQ.
// A nutzap without DLEQ can't be checked by the recipient (NIP-61), so a
// mint whose proofs lack it is skipped before any swap.
func (w *Wallet) mintSupportsDLEQ(mint string) bool {
	for _, p := range w.mintProofs(mint) {
		if p.DLEQ == nil {
			return false
		}
	}
	return true
}

func nutzapTemplate(now int64, req NutzapRequest, r Reserved) (Template, error) {
	lock := "02" + req.Info.Pubkey
	tags := nostr.Tags{}
	for _, p := range r.Proofs {
		if p.DLEQ == nil || p.DLEQ.R == "" {
			return Template{}, fmt.Errorf("wallet: mint gave no DLEQ; the nutzap can't be checked")
		}
		sec, err := nut10.DeserializeSecret(p.Secret)
		if err != nil || sec.Kind != nut10.P2PK || !strings.EqualFold(sec.Data.Data, lock) {
			return Template{}, fmt.Errorf("wallet: sent proofs are not locked to the recipient")
		}
		p.Witness = ""
		b, _ := json.Marshal(p)
		tags = append(tags, nostr.Tag{"proof", string(b)})
	}
	tags = append(tags, nostr.Tag{"unit", "sat"}, nostr.Tag{"u", r.Mint})
	if req.EventID != "" {
		tags = append(tags, nostr.Tag{"e", req.EventID, req.Relay})
		if req.EventKind > 0 {
			tags = append(tags, nostr.Tag{"k", fmt.Sprint(req.EventKind)})
		}
	}
	tags = append(tags, nostr.Tag{"p", req.Recipient})
	return Template{Kind: KindNutzap, CreatedAt: now, Tags: tags, Content: req.Comment,
		Where: WhereRecipient, Relays: append([]string(nil), req.Info.Relays...)}, nil
}

// Nutzap is a 9321 that passed VerifyNutzap.
type Nutzap struct {
	EventID string       `json:"event_id"`
	Sender  string       `json:"sender"`
	Mint    string       `json:"mint"`
	Amount  uint64       `json:"amount"`
	Comment string       `json:"comment,omitempty"`
	ZapOf   string       `json:"zap_of,omitempty"` // the note zapped
	Proofs  cashu.Proofs `json:"proofs"`
	// Shared is set when someone else could also claim it (extra pubkeys,
	// or a refund key / locktime). Count it only once it is redeemed.
	Shared bool `json:"shared,omitempty"`
}

// VerifyNutzap checks a 9321 sent to account (our account pubkey) per
// NIP-61: signed, tagged to us, from a mint in our 10019 (myMints) and held
// in this wallet, every proof P2PK-locked to our wallet key with one
// signature needed, from that mint's keyset, with a valid DLEQ (NUT-12)
// proving the mint signed it.
func (w *Wallet) VerifyNutzap(ctx context.Context, ev nostr.Event, account string, myMints []string) (Nutzap, error) {
	bad := func(why string, a ...any) (Nutzap, error) {
		return Nutzap{}, fmt.Errorf("%w: %s", ErrBadNutzap, fmt.Sprintf(why, a...))
	}
	if err := checkSigned(ev, KindNutzap, ""); err != nil {
		return bad("%v", err)
	}
	pk := w.WalletPubkey()
	if pk == "" {
		return bad("no wallet key")
	}
	lock := "02" + pk
	var mint string
	var proofs cashu.Proofs
	toUs := false
	nz := Nutzap{EventID: ev.ID, Sender: ev.PubKey, Comment: ev.Content}
	for _, t := range ev.Tags {
		if len(t) < 2 {
			continue
		}
		switch t[0] {
		case "u":
			u, err := NormalizeMintURL(t[1])
			if err != nil {
				return bad("mint url: %v", err)
			}
			if mint != "" && mint != u {
				return bad("more than one mint")
			}
			mint = u
		case "unit":
			if t[1] != "sat" {
				return bad("unit %q", t[1])
			}
		case "p":
			if t[1] == account {
				toUs = true
			}
		case "e":
			if nz.ZapOf == "" {
				nz.ZapOf = t[1]
			}
		case "proof":
			var p cashu.Proof
			if err := json.Unmarshal([]byte(t[1]), &p); err != nil {
				return bad("unreadable proof")
			}
			proofs = append(proofs, p)
		}
	}
	if !toUs {
		return bad("not tagged to us")
	}
	if mint == "" || len(proofs) == 0 {
		return bad("no mint or no proofs")
	}
	if !contains(myMints, mint) {
		return bad("mint %s is not in our 10019", mint)
	}
	if cashu.CheckDuplicateProofs(proofs) {
		return bad("duplicate proofs")
	}
	c, err := w.client(mint)
	if err != nil {
		return Nutzap{}, err
	}
	w.mu.Lock()
	sets := map[string]Keyset{}
	if ms := w.state.Mints[mint]; ms != nil {
		for id, ks := range ms.Keysets {
			sets[id] = ks
		}
	}
	w.mu.Unlock()
	for _, p := range proofs {
		if _, ok := sets[p.Id]; !ok {
			if sets, err = w.loadKeysets(ctx, c); err != nil {
				return Nutzap{}, err
			}
			break
		}
	}
	for _, p := range proofs {
		set, ok := sets[p.Id]
		if !ok {
			return bad("proof keyset %s is not from %s", p.Id, mint)
		}
		sec, err := nut10.DeserializeSecret(p.Secret)
		if err != nil || sec.Kind != nut10.P2PK || !strings.EqualFold(sec.Data.Data, lock) {
			return bad("proof not locked to our wallet key")
		}
		tags, err := nut11.ParseP2PKTags(sec.Data.Tags)
		if err != nil {
			return bad("proof lock tags: %v", err)
		}
		if tags.Sigflag == nut11.SIGALL || tags.NSigs > 1 {
			return bad("proof needs more than our one signature")
		}
		if len(tags.Pubkeys) > 0 || len(tags.Refund) > 0 || tags.Locktime > 0 {
			nz.Shared = true
		}
		if p.DLEQ == nil || p.DLEQ.R == "" {
			return bad("proof has no DLEQ")
		}
		K, err := set.pubkey(p.Amount)
		if err != nil || !nut12.VerifyProofDLEQ(p, K) {
			return bad("proof failed its DLEQ check")
		}
		nz.Amount += p.Amount
	}
	nz.Mint = mint
	nz.Proofs = proofs
	return nz, nil
}

// RedeemNutzap claims a verified nutzap: the proofs are swapped at the mint
// into ours (signed with the wallet key). It returns the sats added and the
// history entry to publish (add the new 7375 id to Created after the
// rollover). ErrAlreadySpent means another of our devices (or a refund)
// claimed it first.
func (w *Wallet) RedeemNutzap(ctx context.Context, nz Nutzap, relay string) (uint64, HistoryEntry, error) {
	key, err := w.signKey()
	if err != nil {
		return 0, HistoryEntry{}, err
	}
	got, err := w.Receive(ctx, nz.Mint, nz.Proofs, key, "nutzap "+short(nz.EventID))
	if err != nil {
		return 0, HistoryEntry{}, err
	}
	return got, HistoryEntry{In: true, Amount: got,
		Redeemed: []RedeemRef{{EventID: nz.EventID, Relay: relay, Sender: nz.Sender}}}, nil
}
