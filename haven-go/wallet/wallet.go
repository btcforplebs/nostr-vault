package wallet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/elnosh/gonuts/cashu"
)

var (
	// ErrPending means the mint's answer is not known yet (network, timeout,
	// or a Lightning payment still in flight). The op is journaled; Recover
	// finishes it. The money is not lost and must not be spent again.
	ErrPending = errors.New("wallet: mint answer unknown, kept for recovery")
	// ErrNotEnough means the balance at that mint can't cover amount + fees.
	ErrNotEnough = errors.New("wallet: not enough balance at this mint")
	// ErrUnknownMint means the mint was never added to the wallet.
	ErrUnknownMint = errors.New("wallet: mint not in this wallet")
	// ErrAlreadySpent means the mint says the proofs were already spent
	// (claimed by someone else, or spent by another of our devices).
	ErrAlreadySpent = errors.New("wallet: proofs already spent")
	// ErrNotPaid means a mint quote's invoice has not been paid yet.
	ErrNotPaid = errors.New("wallet: invoice not paid yet")
	// ErrBusy means the mint has an unfinished op; run Recover first.
	ErrBusy = errors.New("wallet: an earlier operation at this mint is unfinished")
	// ErrOwnProofs: the proofs are already ours (often our own waiting
	// token pasted back). Take it back instead.
	ErrOwnProofs = errors.New("wallet: these proofs are already in this wallet")
	// ErrNoChange means paying would overshoot and the mint can't return
	// change (no NUT-08). Nothing was spent.
	ErrNoChange = errors.New("wallet: mint can't return change")
)

// errCrash is what a test hook returns to stop an op as if the app died.
var errCrash = errors.New("wallet: simulated crash")

// Wallet holds proofs at one or more mints. It is safe for concurrent use:
// money operations run one at a time; reads (Balance, State) never wait on a
// mint call.
type Wallet struct {
	store Store

	opMu sync.Mutex // one money operation at a time
	mu   sync.Mutex // guards state and clients

	state   *State
	clients map[string]*Client

	now func() time.Time
	// hook is called at named steps (tests): a non-nil error stops the op
	// right there, the way a killed app would.
	hook func(step string) error
	// newClient lets tests swap in a client; default NewClient.
	newClient func(string) (*Client, error)
}

// Open loads the wallet from store.
func Open(store Store) (*Wallet, error) {
	s, err := store.Load()
	if err != nil {
		return nil, err
	}
	return &Wallet{store: store, state: s, clients: map[string]*Client{}, now: time.Now, newClient: NewClient}, nil
}

func (w *Wallet) step(name string) error {
	if w.hook != nil {
		return w.hook(name)
	}
	return nil
}

func (w *Wallet) newID() string {
	id, err := randomHex(16)
	if err != nil {
		panic(err)
	}
	return id
}

// commit applies mutate to a copy of the state, saves the copy, and only then
// makes it current. If Save fails, nothing changes.
func (w *Wallet) commit(mutate func(*State) error) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	next := w.state.clone()
	if err := mutate(next); err != nil {
		return err
	}
	if err := w.store.Save(next); err != nil {
		return fmt.Errorf("wallet: save failed: %w", err)
	}
	w.state = next
	return nil
}

func (w *Wallet) client(mint string) (*Client, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if _, ok := w.state.Mints[mint]; !ok {
		return nil, ErrUnknownMint
	}
	if c, ok := w.clients[mint]; ok {
		return c, nil
	}
	c, err := w.newClient(mint)
	if err != nil {
		return nil, err
	}
	w.clients[mint] = c
	return c, nil
}

// MintSummary is what the app shows when a mint is added (trust info, §2).
type MintSummary struct {
	URL         string `json:"url"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Version     string `json:"version,omitempty"`
	MOTD        string `json:"motd,omitempty"`
	Checkstate  bool   `json:"nut07"` // can tell spent proofs
	Restore     bool   `json:"nut09"` // can recover outputs after a crash
	P2PK        bool   `json:"nut11"` // can receive nutzaps
	DLEQ        bool   `json:"nut12"` // proofs carry DLEQ
	Sat         bool   `json:"sat"`   // has an active sat keyset
}

// AddMint checks a mint (NUT-06 info, an active sat keyset with a valid id)
// and adds it to the wallet. Adding a mint already present refreshes it.
func (w *Wallet) AddMint(ctx context.Context, mintURL string) (MintSummary, error) {
	u, err := NormalizeMintURL(mintURL)
	if err != nil {
		return MintSummary{}, err
	}
	c, err := w.newClient(u)
	if err != nil {
		return MintSummary{}, err
	}
	info, err := c.Info(ctx)
	if err != nil {
		return MintSummary{}, fmt.Errorf("mint info: %w", err)
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	if err := w.commit(func(s *State) error {
		if s.Mints[u] == nil {
			s.Mints[u] = &MintState{URL: u}
		}
		return nil
	}); err != nil {
		return MintSummary{}, err
	}
	w.mu.Lock()
	w.clients[u] = c
	w.mu.Unlock()
	sets, err := w.loadKeysets(ctx, c)
	if err != nil {
		return MintSummary{}, err
	}
	_, ksErr := activeKeyset(sets)
	sum := MintSummary{
		URL: u, Name: info.Name, Description: info.Description, Version: info.Version, MOTD: info.Motd,
		Checkstate: info.Nuts.Nut07.Supported, Restore: info.Nuts.Nut09.Supported,
		P2PK: info.Nuts.Nut11.Supported, DLEQ: info.Nuts.Nut12.Supported, Sat: ksErr == nil,
	}
	return sum, w.commit(func(*State) error { return nil }) // persist keysets
}

// RemoveMint drops a mint. It refuses while the mint holds any balance,
// reserved proofs, journaled ops or open quotes: move the balance first.
func (w *Wallet) RemoveMint(mintURL string) error {
	u, err := NormalizeMintURL(mintURL)
	if err != nil {
		return err
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	return w.commit(func(s *State) error {
		ms := s.Mints[u]
		if ms == nil {
			return ErrUnknownMint
		}
		if len(ms.Proofs) > 0 {
			return fmt.Errorf("wallet: %s still holds %d sats; move them first", u, ms.Proofs.Amount())
		}
		for _, op := range s.Ops {
			if op.Mint == u {
				return ErrBusy
			}
		}
		for _, r := range s.Reserved {
			if r.Mint == u {
				return fmt.Errorf("wallet: %s has sent proofs not yet claimed", u)
			}
		}
		for _, q := range s.MintQuotes {
			if q.Mint == u {
				return fmt.Errorf("wallet: %s has an open receive invoice", u)
			}
		}
		delete(s.Mints, u)
		return nil
	})
}

// Balance is the spendable total per mint. Warn is set at WarnBalanceSats.
type Balance struct {
	Total    uint64            `json:"total"`
	PerMint  map[string]uint64 `json:"per_mint"`
	Reserved uint64            `json:"reserved"` // sent, not yet claimed
	// ReservedPerMint is Reserved by mint: the "Waiting for … to claim"
	// amount on each mint row (exported tokens and unclaimed nutzaps).
	ReservedPerMint map[string]uint64 `json:"reserved_per_mint,omitempty"`
	InFlight        uint64            `json:"in_flight"`
	Warn            bool              `json:"warn"`
}

func (w *Wallet) Balance() Balance {
	w.mu.Lock()
	defer w.mu.Unlock()
	b := Balance{PerMint: map[string]uint64{}}
	for u, ms := range w.state.Mints {
		a := ms.Proofs.Amount()
		b.PerMint[u] = a
		b.Total += a
	}
	for _, r := range w.state.Reserved {
		a := r.Proofs.Amount()
		b.Reserved += a
		if a > 0 {
			if b.ReservedPerMint == nil {
				b.ReservedPerMint = map[string]uint64{}
			}
			b.ReservedPerMint[r.Mint] += a
		}
	}
	for _, op := range w.state.Ops {
		if op.Kind != OpReclaim { // reclaim inputs are still counted as Reserved
			b.InFlight += op.Inputs.Amount()
		}
	}
	b.Warn = b.Total+b.InFlight >= WarnBalanceSats
	return b
}

// Mints lists the wallet's mints, sorted.
func (w *Wallet) Mints() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]string, 0, len(w.state.Mints))
	for u := range w.state.Mints {
		out = append(out, u)
	}
	sort.Strings(out)
	return out
}

// StateJSON is the whole state as JSON (for E2/E3: the app encrypts it to
// self and publishes to the Vault /private relay).
func (w *Wallet) StateJSON() ([]byte, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return json.Marshal(w.state)
}

// Pending lists unfinished ops (for the app's "finishing a payment" line).
func (w *Wallet) Pending() []Op {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state.clone().Ops
}

// ReservedSets lists sent proofs not yet claimed.
func (w *Wallet) ReservedSets() []Reserved {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state.clone().Reserved
}

func (w *Wallet) mintBusy(mint string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, op := range w.state.Ops {
		// A stuck op already holds its inputs out of the balance, so it can't
		// clash with a new op; only an op whose answer is unknown blocks.
		if op.Mint == mint && op.Stuck == "" {
			return true
		}
	}
	return false
}

// reservedBusy reports an op (stuck or not) already reclaiming Reserved set
// id: its inputs are that set's proofs, so a second reclaim would spend them
// again and read our own swap as someone else's claim.
func (w *Wallet) reservedBusy(id string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, op := range w.state.Ops {
		if op.Reserved == id {
			return true
		}
	}
	return false
}

// selectProofs picks proofs (largest first) until they cover target plus
// their own input fee. It returns the picked proofs and that fee.
func selectProofs(have cashu.Proofs, target uint64, sets map[string]Keyset) (cashu.Proofs, uint64, error) {
	sorted := append(cashu.Proofs(nil), have...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Amount > sorted[j].Amount })
	var picked cashu.Proofs
	var sum uint64
	for _, p := range sorted {
		if _, ok := sets[p.Id]; !ok {
			continue // keyset unknown to this mint any more; can't price or spend it
		}
		picked = append(picked, p)
		sum += p.Amount
		if fee := inputFee(picked, sets); sum >= target+fee {
			return picked, fee, nil
		}
	}
	return nil, 0, ErrNotEnough
}

func (w *Wallet) mintProofs(mint string) cashu.Proofs {
	w.mu.Lock()
	defer w.mu.Unlock()
	ms := w.state.Mints[mint]
	if ms == nil {
		return nil
	}
	return append(cashu.Proofs(nil), ms.Proofs...)
}
