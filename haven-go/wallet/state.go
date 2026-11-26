package wallet

import (
	"encoding/json"

	"github.com/elnosh/gonuts/cashu"
)

// StateVersion is bumped when the State JSON changes shape.
const StateVersion = 1

// WarnBalanceSats is Logen's warning line (2026-11-25): at or above it the app
// shows a warning. It never blocks incoming money.
const WarnBalanceSats uint64 = 100_000

// State is everything the wallet knows. It is plain JSON so an app can keep it
// in its own secret store (Keychain, Android secrets, IndexedDB) through E3.
type State struct {
	Version    int                   `json:"version"`
	Mints      map[string]*MintState `json:"mints"`
	Ops        []Op                  `json:"ops,omitempty"`
	MintQuotes []MintQuote           `json:"mint_quotes,omitempty"`
	Reserved   []Reserved            `json:"reserved,omitempty"`

	// NIP-60 event layer (E2). WalletKey is the 17375 wallet key (hex): NOT
	// the account key; it only unlocks nutzaps locked to us. WalletDigest is
	// what the last published 17375 held. Tokens indexes the 7375 events we
	// know are live; QuoteEvents maps a mint quote id to its 7374 event.
	WalletKey    string            `json:"wallet_key,omitempty"`
	WalletDigest string            `json:"wallet_digest,omitempty"`
	Tokens       []PublishedToken  `json:"tokens,omitempty"`
	QuoteEvents  map[string]string `json:"quote_events,omitempty"`
	// PendingDeletes are 7375 ids already replaced by a published 7375 (and
	// named in its del), still owed a kind-5. A kind-5 is only ever sent for
	// an id whose replacement is committed, so a failed publish never leaves
	// the Vault without the proofs.
	PendingDeletes []string `json:"pending_deletes,omitempty"`
}

// PublishedToken is one live 7375 we know of.
type PublishedToken struct {
	EventID string `json:"event_id"`
	Mint    string `json:"mint"`
	Group   string `json:"group"`
	Digest  string `json:"digest"`
}

// MintState is one mint and the proofs we hold there.
type MintState struct {
	URL    string       `json:"url"`
	Proofs cashu.Proofs `json:"proofs"`
	// Keysets we have seen, keyed by id. Public keys only.
	Keysets map[string]Keyset `json:"keysets,omitempty"`
}

// OpKind names a journaled operation.
type OpKind string

const (
	OpMint    OpKind = "mint"    // NUT-04: quote paid, outputs to be signed
	OpSwap    OpKind = "swap"    // NUT-03: our proofs split into keep + send
	OpReceive OpKind = "receive" // NUT-03: someone else's proofs swapped into ours
	OpMelt    OpKind = "melt"    // NUT-05: our proofs pay an invoice, change back
	OpReclaim OpKind = "reclaim" // NUT-03: reserved (sent, unclaimed) proofs swapped back
)

// OutputRole says where a signed output goes.
type OutputRole string

const (
	RoleKeep   OutputRole = "keep"   // into the balance
	RoleSend   OutputRole = "send"   // into Reserved, handed to the caller
	RoleChange OutputRole = "change" // NUT-08 blank output (melt change)
)

// PendingOutput is one blinded message we built, with what we need to unblind
// its signature later. Secret and R are secret: whoever has them and the
// signature can spend the proof.
type PendingOutput struct {
	Amount   uint64     `json:"amount"`
	KeysetID string     `json:"id"`
	Secret   string     `json:"secret"`
	R        string     `json:"r"`  // blinding factor, hex
	B        string     `json:"B_"` // blinded message, hex
	Role     OutputRole `json:"role"`
}

// Op is a journaled operation. It is saved before the mint is called and
// removed only when the mint's answer is known and applied.
type Op struct {
	ID       string          `json:"id"`
	Kind     OpKind          `json:"kind"`
	Mint     string          `json:"mint"`
	Inputs   cashu.Proofs    `json:"inputs,omitempty"`
	Outputs  []PendingOutput `json:"outputs,omitempty"`
	Quote    string          `json:"quote,omitempty"`
	Reserved string          `json:"reserved,omitempty"` // OpReclaim: the Reserved set id
	Memo     string          `json:"memo,omitempty"`
	Created  int64           `json:"created"`
	// Stuck is set when Recover could not finish the op (for example the mint
	// signed but has no NUT-09 restore). The op stays; nothing is dropped.
	Stuck string `json:"stuck,omitempty"`
}

// MintQuote is a NUT-04 quote we asked for (the local twin of a 7374 event),
// kept so an unpaid "Receive" invoice survives a restart.
type MintQuote struct {
	ID      string `json:"id"`
	Mint    string `json:"mint"`
	Amount  uint64 `json:"amount"`
	Request string `json:"request"` // bolt11 to pay
	Expiry  uint64 `json:"expiry,omitempty"`
	Created int64  `json:"created"`
}

// Reserved is a set of proofs we swapped out to give to someone (a token or a
// nutzap). They are not in the balance. CheckState drops them once the mint
// says they are spent (claimed); Reclaim swaps them back if they never were.
type Reserved struct {
	ID      string       `json:"id"`
	Mint    string       `json:"mint"`
	Proofs  cashu.Proofs `json:"proofs"`
	Memo    string       `json:"memo,omitempty"`
	Created int64        `json:"created"`
}

func newState() *State {
	return &State{Version: StateVersion, Mints: map[string]*MintState{}}
}

// clone deep-copies the state through JSON, so a failed save never leaves the
// in-memory copy half changed.
func (s *State) clone() *State {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err) // plain data; cannot fail
	}
	c := newState()
	if err := json.Unmarshal(b, c); err != nil {
		panic(err)
	}
	if c.Mints == nil {
		c.Mints = map[string]*MintState{}
	}
	return c
}

func (s *State) findOp(id string) int {
	for i := range s.Ops {
		if s.Ops[i].ID == id {
			return i
		}
	}
	return -1
}

func (s *State) removeOp(id string) {
	if i := s.findOp(id); i >= 0 {
		s.Ops = append(s.Ops[:i], s.Ops[i+1:]...)
	}
}

func (s *State) findReserved(id string) int {
	for i := range s.Reserved {
		if s.Reserved[i].ID == id {
			return i
		}
	}
	return -1
}

// addProofs adds proofs to a mint's balance, skipping any secret already held.
func (s *State) addProofs(mint string, proofs cashu.Proofs) {
	ms := s.Mints[mint]
	if ms == nil {
		ms = &MintState{URL: mint}
		s.Mints[mint] = ms
	}
	have := map[string]bool{}
	for _, p := range ms.Proofs {
		have[p.Secret] = true
	}
	for _, p := range proofs {
		if !have[p.Secret] {
			ms.Proofs = append(ms.Proofs, p)
			have[p.Secret] = true
		}
	}
}

// takeProofs removes proofs (by secret) from a mint's balance.
func (s *State) takeProofs(mint string, proofs cashu.Proofs) {
	ms := s.Mints[mint]
	if ms == nil {
		return
	}
	drop := map[string]bool{}
	for _, p := range proofs {
		drop[p.Secret] = true
	}
	kept := ms.Proofs[:0]
	for _, p := range ms.Proofs {
		if !drop[p.Secret] {
			kept = append(kept, p)
		}
	}
	ms.Proofs = kept
}
