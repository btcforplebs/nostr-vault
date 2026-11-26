package wallet

// kind 7376 spending history. The NIP-44-to-self content is a tag list:
// ["direction","in"|"out"], ["amount",n], ["unit","sat"] and
// ["e",<7375 id>,"","created"|"destroyed"]. A redeemed nutzap adds the public
// tags ["e",<9321 id>,<relay>,"redeemed"] and ["p",<sender>], so every device
// can see which nutzaps are already claimed without decrypting.

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/nbd-wtf/go-nostr"
)

// HistoryEntry is one 7376.
type HistoryEntry struct {
	EventID   string      `json:"event_id,omitempty"`
	CreatedAt int64       `json:"created_at,omitempty"`
	In        bool        `json:"in"`
	Amount    uint64      `json:"amount"`
	Created   []string    `json:"created,omitempty"`   // 7375 ids made
	Destroyed []string    `json:"destroyed,omitempty"` // 7375 ids replaced
	Redeemed  []RedeemRef `json:"redeemed,omitempty"`  // nutzaps claimed
}

// RedeemRef points at a claimed 9321.
type RedeemRef struct {
	EventID string `json:"event_id"`
	Relay   string `json:"relay,omitempty"`
	Sender  string `json:"sender,omitempty"`
}

// HistoryTemplate builds a 7376 for the app to encrypt, sign and publish to
// the Vault.
func (w *Wallet) HistoryTemplate(h HistoryEntry) (Template, error) {
	if h.Amount == 0 {
		return Template{}, fmt.Errorf("wallet: history amount must be above 0")
	}
	dir := "out"
	if h.In {
		dir = "in"
	}
	enc := nostr.Tags{{"direction", dir}, {"amount", strconv.FormatUint(h.Amount, 10)}, {"unit", "sat"}}
	for _, id := range h.Created {
		enc = append(enc, nostr.Tag{"e", id, "", "created"})
	}
	for _, id := range h.Destroyed {
		enc = append(enc, nostr.Tag{"e", id, "", "destroyed"})
	}
	pub := nostr.Tags{}
	for _, r := range h.Redeemed {
		pub = append(pub, nostr.Tag{"e", r.EventID, r.Relay, "redeemed"})
		if r.Sender != "" {
			pub = append(pub, nostr.Tag{"p", r.Sender})
		}
	}
	b, err := json.Marshal(enc)
	if err != nil {
		return Template{}, err
	}
	return Template{Kind: KindHistory, CreatedAt: w.now().Unix(), Tags: pub, Content: string(b),
		Encrypt: true, Where: WherePrivate}, nil
}

// ParseHistory reads a 7376 (encrypted and public tags together).
func ParseHistory(oe OwnEvent, author string) (HistoryEntry, error) {
	if err := checkSigned(oe.Event, KindHistory, author); err != nil {
		return HistoryEntry{}, err
	}
	var tags nostr.Tags
	if oe.Plaintext != "" {
		if err := json.Unmarshal([]byte(oe.Plaintext), &tags); err != nil {
			return HistoryEntry{}, fmt.Errorf("%w: 7376 content is not a tag list", ErrBadEvent)
		}
	}
	h := HistoryEntry{EventID: oe.Event.ID, CreatedAt: int64(oe.Event.CreatedAt)}
	sawDir := false
	var lastRedeem = -1
	for _, t := range append(tags, oe.Event.Tags...) {
		if len(t) < 2 {
			continue
		}
		switch t[0] {
		case "direction":
			switch t[1] {
			case "in":
				h.In, sawDir = true, true
			case "out":
				h.In, sawDir = false, true
			default:
				return HistoryEntry{}, fmt.Errorf("%w: 7376 direction %q", ErrBadEvent, t[1])
			}
		case "amount":
			v, err := strconv.ParseUint(t[1], 10, 64)
			if err != nil {
				return HistoryEntry{}, fmt.Errorf("%w: 7376 amount %q", ErrBadEvent, t[1])
			}
			h.Amount = v
		case "e":
			if len(t) < 4 {
				continue
			}
			switch t[3] {
			case "created":
				h.Created = append(h.Created, t[1])
			case "destroyed":
				h.Destroyed = append(h.Destroyed, t[1])
			case "redeemed":
				h.Redeemed = append(h.Redeemed, RedeemRef{EventID: t[1], Relay: t[2]})
				lastRedeem = len(h.Redeemed) - 1
			}
		case "p":
			if lastRedeem >= 0 && h.Redeemed[lastRedeem].Sender == "" {
				h.Redeemed[lastRedeem].Sender = t[1]
			}
		}
	}
	if !sawDir || h.Amount == 0 {
		return HistoryEntry{}, fmt.Errorf("%w: 7376 needs direction and amount", ErrBadEvent)
	}
	return h, nil
}

// RedeemedNutzaps is the set of 9321 ids the history says are claimed. It
// only reads public tags, so it works without decrypting.
func RedeemedNutzaps(history []nostr.Event, author string) map[string]bool {
	out := map[string]bool{}
	for _, ev := range history {
		if checkSigned(ev, KindHistory, author) != nil {
			continue
		}
		for _, t := range ev.Tags {
			if len(t) >= 4 && t[0] == "e" && t[3] == "redeemed" {
				out[t[1]] = true
			}
		}
	}
	return out
}
