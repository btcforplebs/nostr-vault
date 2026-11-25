package wallet

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/crypto"
)

// Keyset is a mint keyset's public half (NUT-01/02).
type Keyset struct {
	ID          string            `json:"id"`
	Unit        string            `json:"unit"`
	Active      bool              `json:"active"`
	InputFeePpk uint              `json:"input_fee_ppk,omitempty"`
	Keys        map[uint64]string `json:"keys"` // amount -> compressed pubkey hex
}

func (k Keyset) pubkey(amount uint64) (*secp256k1.PublicKey, error) {
	h, ok := k.Keys[amount]
	if !ok {
		return nil, fmt.Errorf("keyset %s has no key for amount %d", k.ID, amount)
	}
	b, err := hex.DecodeString(h)
	if err != nil {
		return nil, err
	}
	return secp256k1.ParsePubKey(b)
}

// verifyKeysetID checks that a version-00 keyset id is the hash of its keys,
// so a mint can't hand one user keys of their own under a shared id. Other id
// versions are accepted unchecked for now (gonuts v0.4.2 derives 00 only).
func verifyKeysetID(id string, keys map[uint64]string) error {
	if !strings.HasPrefix(id, "00") {
		return nil
	}
	pks := make(map[uint64]*secp256k1.PublicKey, len(keys))
	for amt, h := range keys {
		b, err := hex.DecodeString(h)
		if err != nil {
			return fmt.Errorf("keyset %s: bad key for %d", id, amt)
		}
		pk, err := secp256k1.ParsePubKey(b)
		if err != nil {
			return fmt.Errorf("keyset %s: bad key for %d", id, amt)
		}
		pks[amt] = pk
	}
	if got := crypto.DeriveKeysetId(pks); got != id {
		return fmt.Errorf("keyset id %s does not match its keys (%s)", id, got)
	}
	return nil
}

// loadKeysets refreshes the mint's keyset list and fetches keys for any sat
// keyset we don't have yet. Keys we already hold are never replaced: a keyset
// id names one fixed set of keys.
func (w *Wallet) loadKeysets(ctx context.Context, c *Client) (map[string]Keyset, error) {
	list, err := c.Keysets(ctx)
	if err != nil {
		return nil, err
	}
	w.mu.Lock()
	known := map[string]Keyset{}
	if ms := w.state.Mints[c.URL]; ms != nil {
		for id, ks := range ms.Keysets {
			known[id] = ks
		}
	}
	w.mu.Unlock()

	out := map[string]Keyset{}
	for _, info := range list.Keysets {
		if info.Unit != cashu.Sat.String() {
			continue
		}
		ks, ok := known[info.Id]
		if !ok {
			resp, err := c.Keys(ctx, info.Id)
			if err != nil {
				return nil, err
			}
			var found bool
			for _, k := range resp.Keysets {
				if k.Id != info.Id {
					continue
				}
				if err := verifyKeysetID(k.Id, k.Keys); err != nil {
					return nil, err
				}
				ks = Keyset{ID: k.Id, Unit: k.Unit, Keys: map[uint64]string(k.Keys)}
				found = true
			}
			if !found {
				return nil, fmt.Errorf("mint did not return keys for keyset %s", info.Id)
			}
		}
		ks.Active = info.Active
		ks.InputFeePpk = info.InputFeePpk
		out[info.Id] = ks
	}
	// Keep keysets the mint no longer lists (old proofs may use them).
	for id, ks := range known {
		if _, ok := out[id]; !ok {
			ks.Active = false
			out[id] = ks
		}
	}
	w.mu.Lock()
	ms := w.state.Mints[c.URL]
	if ms != nil {
		ms.Keysets = out
	}
	w.mu.Unlock()
	return out, nil
}

// activeKeyset is the active sat keyset with the lowest input fee.
func activeKeyset(sets map[string]Keyset) (Keyset, error) {
	var best Keyset
	found := false
	for _, ks := range sets {
		if !ks.Active || ks.Unit != cashu.Sat.String() {
			continue
		}
		if !found || ks.InputFeePpk < best.InputFeePpk || (ks.InputFeePpk == best.InputFeePpk && ks.ID < best.ID) {
			best, found = ks, true
		}
	}
	if !found {
		return Keyset{}, fmt.Errorf("mint has no active sat keyset")
	}
	return best, nil
}

// inputFee is the NUT-02 fee for spending these proofs: ceil(sum ppk / 1000).
func inputFee(proofs cashu.Proofs, sets map[string]Keyset) uint64 {
	var ppk uint64
	for _, p := range proofs {
		ppk += uint64(sets[p.Id].InputFeePpk)
	}
	return (ppk + 999) / 1000
}
