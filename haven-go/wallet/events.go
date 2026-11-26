package wallet

// NIP-60/61 event layer (PR E2, design RESEARCH/NV_CASHU_WALLET_DESIGN_2026_11_25.md §2).
//
// The engine never signs and never encrypts: the apps keep every signer
// operation (nsec, bunker, Amber, NIP-07). So this layer works on plain data:
//   - Build* and Rollover return Templates: kind, tags and the PLAINTEXT
//     content. When Encrypt is set the app NIP-44-encrypts Content to its own
//     pubkey, puts the ciphertext in content, signs and publishes.
//   - Parse*/Restore take the signed event as read from the relay plus the
//     plaintext the app decrypted (OwnEvent).
//
// Where each event goes follows Logen's pick (b) (§2a): every wallet event
// (17375, 7375, 7376, 7374 and their kind-5 deletions) goes to the account's
// own Vault /private relay only. Only 10019 and outgoing 9321 nutzaps are
// public.

import (
	"errors"
	"fmt"

	"github.com/nbd-wtf/go-nostr"
)

// Event kinds (NIP-60, NIP-61, NIP-09).
const (
	KindWallet     = 17375 // wallet: wallet key + mints (replaceable)
	KindToken      = 7375  // unspent proofs at one mint
	KindHistory    = 7376  // spending history
	KindQuote      = 7374  // pending mint quote
	KindNutzapInfo = 10019 // where and how to nutzap us (public)
	KindNutzap     = 9321  // a nutzap (public)
	KindDeletion   = 5
)

// Where says which relays a Template goes to.
type Where string

const (
	// WherePrivate is the account's own Vault /private relay (all copies of
	// the owner's Vaults through mesh copy v2). Never a public relay.
	WherePrivate Where = "private"
	// WherePublic is the account's NIP-65 write relays (10019).
	WherePublic Where = "public"
	// WhereRecipient is the relays in the recipient's 10019 (a 9321).
	WhereRecipient Where = "recipient"
)

// Template is an event for the app to (encrypt,) sign and publish.
type Template struct {
	Kind      int        `json:"kind"`
	CreatedAt int64      `json:"created_at"`
	Tags      nostr.Tags `json:"tags"`
	// Content is plaintext. With Encrypt set, NIP-44-encrypt it to self
	// before signing; never publish it as is.
	Content string `json:"content"`
	Encrypt bool   `json:"encrypt"`
	Where   Where  `json:"where"`
	// Relays, for WhereRecipient: the recipient's 10019 relays.
	Relays []string `json:"relays,omitempty"`
	// Meta tells CommitPublished what this event stands for. Hand it back
	// unchanged.
	Meta *TemplateMeta `json:"meta,omitempty"`
}

// TemplateMeta is the engine's bookkeeping for a published template.
type TemplateMeta struct {
	Group    string   `json:"group,omitempty"`    // 7375: token group (see tokenGroup)
	Mint     string   `json:"mint,omitempty"`     // 7375/7374
	Digest   string   `json:"digest,omitempty"`   // 7375/17375: what the event holds
	Replaces []string `json:"replaces,omitempty"` // 7375: older 7375 ids it replaces (its del)
	Deletes  []string `json:"deletes,omitempty"`  // kind 5: ids it deletes
	Quote    string   `json:"quote,omitempty"`    // 7374: quote id
}

// OwnEvent is one of the account's own encrypted events as read from its
// Vault, with the plaintext the app decrypted from Content.
type OwnEvent struct {
	Event     nostr.Event `json:"event"`
	Plaintext string      `json:"plaintext"`
}

var (
	// ErrBadEvent means an event is not what it claims (wrong kind, author,
	// id or signature, or unreadable content). It is skipped, never trusted.
	ErrBadEvent = errors.New("wallet: bad event")
	// ErrKeyConflict means the Vault holds a different wallet key than this
	// device. Nothing is replaced; the app must ask the user.
	ErrKeyConflict = errors.New("wallet: a different wallet key is already set")
)

// checkSigned checks an event's kind, author, id and signature.
func checkSigned(ev nostr.Event, kind int, author string) error {
	if ev.Kind != kind {
		return fmt.Errorf("%w: kind %d, want %d", ErrBadEvent, ev.Kind, kind)
	}
	if author != "" && ev.PubKey != author {
		return fmt.Errorf("%w: event %s is not by %s", ErrBadEvent, short(ev.ID), short(author))
	}
	if !ev.CheckID() {
		return fmt.Errorf("%w: event id does not match its content", ErrBadEvent)
	}
	ok, err := ev.CheckSignature()
	if err != nil || !ok {
		return fmt.Errorf("%w: bad signature on %s", ErrBadEvent, short(ev.ID))
	}
	return nil
}

func short(s string) string {
	if len(s) > 8 {
		return s[:8]
	}
	return s
}

// deletionTemplate is a kind-5 (NIP-09) for ids of one kind, with the `k`
// tag NIP-60 restore filters on.
func deletionTemplate(now int64, kind int, ids []string) Template {
	tags := make(nostr.Tags, 0, len(ids)+1)
	for _, id := range ids {
		tags = append(tags, nostr.Tag{"e", id})
	}
	tags = append(tags, nostr.Tag{"k", fmt.Sprint(kind)})
	return Template{Kind: KindDeletion, CreatedAt: now, Tags: tags, Where: WherePrivate,
		Meta: &TemplateMeta{Deletes: append([]string(nil), ids...)}}
}

// deletedIDs collects the ids that the account's kind-5 events delete.
// Deletions by anyone else, or with a bad signature, are ignored.
func deletedIDs(dels []nostr.Event, author string) map[string]bool {
	out := map[string]bool{}
	for _, d := range dels {
		if checkSigned(d, KindDeletion, author) != nil {
			continue
		}
		for _, t := range d.Tags {
			if len(t) >= 2 && t[0] == "e" {
				out[t[1]] = true
			}
		}
	}
	return out
}
