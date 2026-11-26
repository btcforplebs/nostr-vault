package wallet

// kind 17375: the wallet event. Its NIP-44-to-self content is a JSON array of
// tags: ["privkey", <wallet key hex>] and one ["mint", url] per mint. The
// wallet key is a fresh random key, never the account nsec (§2a).

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/schnorr"
	"github.com/nbd-wtf/go-nostr"
)

// WalletInfo is a parsed 17375.
type WalletInfo struct {
	EventID   string   `json:"event_id"`
	CreatedAt int64    `json:"created_at"`
	WalletKey string   `json:"-"` // secret; never logged or handed out as JSON
	Mints     []string `json:"mints"`
}

// CreateWalletKey makes the wallet key for a new wallet. It refuses when a
// key is already set: a second wallet key would split the nutzaps. The app
// must only call it after a finished Vault read found no 17375 (§2 "never
// create a second 17375").
func (w *Wallet) CreateWalletKey() error {
	k, err := btcec.NewPrivateKey()
	if err != nil {
		return err
	}
	w.opMu.Lock()
	defer w.opMu.Unlock()
	return w.commit(func(s *State) error {
		if s.WalletKey != "" {
			return ErrKeyConflict
		}
		s.WalletKey = hex.EncodeToString(k.Serialize())
		return nil
	})
}

// HasWalletKey reports whether the wallet key is set.
func (w *Wallet) HasWalletKey() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state.WalletKey != ""
}

// WalletPubkey is the x-only (32-byte hex) public half of the wallet key: the
// 10019 `pubkey` nutzaps are locked to. Empty when no key is set.
func (w *Wallet) WalletPubkey() string {
	w.mu.Lock()
	k := w.state.WalletKey
	w.mu.Unlock()
	pk, err := walletPubkey(k)
	if err != nil {
		return ""
	}
	return pk
}

func walletPubkey(keyHex string) (string, error) {
	priv, err := parseWalletKey(keyHex)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(schnorr.SerializePubKey(priv.PubKey())), nil
}

func parseWalletKey(keyHex string) (*btcec.PrivateKey, error) {
	b, err := hex.DecodeString(keyHex)
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("wallet: wallet key is not 32-byte hex")
	}
	priv, _ := btcec.PrivKeyFromBytes(b)
	if priv.Key.IsZero() {
		return nil, fmt.Errorf("wallet: wallet key is zero")
	}
	return priv, nil
}

func (w *Wallet) signKey() (*btcec.PrivateKey, error) {
	w.mu.Lock()
	k := w.state.WalletKey
	w.mu.Unlock()
	if k == "" {
		return nil, fmt.Errorf("wallet: no wallet key yet")
	}
	return parseWalletKey(k)
}

// walletDigest names what a 17375 holds (key + sorted mints).
func walletDigest(key string, mints []string) string {
	ms := append([]string(nil), mints...)
	sort.Strings(ms)
	h := sha256.Sum256([]byte(key + "\n" + strings.Join(ms, "\n")))
	return hex.EncodeToString(h[:])
}

func walletTemplate(now int64, key string, mints []string) Template {
	tags := nostr.Tags{{"privkey", key}}
	ms := append([]string(nil), mints...)
	sort.Strings(ms)
	for _, m := range ms {
		tags = append(tags, nostr.Tag{"mint", m})
	}
	b, _ := json.Marshal(tags)
	return Template{Kind: KindWallet, CreatedAt: now, Tags: nostr.Tags{}, Content: string(b),
		Encrypt: true, Where: WherePrivate, Meta: &TemplateMeta{Digest: walletDigest(key, ms)}}
}

// ParseWallet reads a 17375. author is the account pubkey (hex).
func ParseWallet(oe OwnEvent, author string) (WalletInfo, error) {
	if err := checkSigned(oe.Event, KindWallet, author); err != nil {
		return WalletInfo{}, err
	}
	var tags nostr.Tags
	if err := json.Unmarshal([]byte(oe.Plaintext), &tags); err != nil {
		return WalletInfo{}, fmt.Errorf("%w: 17375 content is not a tag list", ErrBadEvent)
	}
	info := WalletInfo{EventID: oe.Event.ID, CreatedAt: int64(oe.Event.CreatedAt)}
	seen := map[string]bool{}
	for _, t := range tags {
		if len(t) < 2 {
			continue
		}
		switch t[0] {
		case "privkey":
			if info.WalletKey != "" && info.WalletKey != t[1] {
				return WalletInfo{}, fmt.Errorf("%w: 17375 has two wallet keys", ErrBadEvent)
			}
			if _, err := parseWalletKey(t[1]); err != nil {
				return WalletInfo{}, fmt.Errorf("%w: %v", ErrBadEvent, err)
			}
			info.WalletKey = strings.ToLower(t[1])
		case "mint":
			u, err := NormalizeMintURL(t[1])
			if err != nil || seen[u] {
				continue // a mint we can't use is skipped, not fatal
			}
			seen[u] = true
			info.Mints = append(info.Mints, u)
		}
	}
	sort.Strings(info.Mints)
	return info, nil
}

// applyWalletInfo takes the wallet key and mints from a 17375 into s. A
// different key already set is a conflict and changes nothing.
func applyWalletInfo(s *State, info WalletInfo) error {
	if info.WalletKey != "" {
		if s.WalletKey != "" && s.WalletKey != info.WalletKey {
			return ErrKeyConflict
		}
		s.WalletKey = info.WalletKey
	}
	for _, m := range info.Mints {
		if s.Mints[m] == nil {
			s.Mints[m] = &MintState{URL: m}
		}
	}
	if s.WalletKey != "" {
		s.WalletDigest = walletDigest(s.WalletKey, info.Mints)
	}
	return nil
}
