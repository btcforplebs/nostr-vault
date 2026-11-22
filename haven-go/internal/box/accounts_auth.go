package box

import (
	"errors"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// AccountStore is the box's account list as the box API sees it: who is
// held and in which state, and the changes the first account (or a joining
// account) makes. Every read goes to box/accounts.json, so a hand edit is
// seen at once; every change rewrites it whole and then calls Changed, which
// havend points at the AccountsWatch so the engine restarts with the new
// lists right away instead of on the next 5 s check.
type AccountStore struct {
	Path      string // box/accounts.json
	OwnerHex  string // the first account
	OwnerNpub string
	Now       func() time.Time
	Changed   func()

	mu sync.Mutex
}

// Account states, as the box API and the web app name them.
const (
	StateFirst     = "first"
	StateSignedIn  = "signedIn"
	StateWatchOnly = "watchOnly"
	StateNone      = "none"
)

var (
	ErrAccountExists = errors.New("this box already holds that account")
	ErrNoAccount     = errors.New("this box doesn't hold that account")
	ErrFirstAccount  = errors.New("that is the box's first account: it can't be added, joined or removed")
)

// AccountView is one account as the box API lists it.
type AccountView struct {
	Npub  string `json:"npub"`
	State string `json:"state"`
	Added int64  `json:"added,omitempty"`
	Name  string `json:"name,omitempty"`
}

// NewAccountStore is the store for cfg's box.
func NewAccountStore(cfg Config) *AccountStore {
	return &AccountStore{Path: cfg.AccountsFile(), OwnerHex: strings.ToLower(cfg.OwnerHex), OwnerNpub: cfg.OwnerNpub, Now: time.Now}
}

func npubOfHex(pk string) string {
	n, err := nip19.EncodePublicKey(strings.ToLower(pk))
	if err != nil {
		return ""
	}
	return n
}

// StateOf: pk's (hex) state on this box. A damaged accounts.json reads as no
// added accounts, as the engine reads it: fail closed.
func (s *AccountStore) StateOf(pk string) string {
	pk = strings.ToLower(pk)
	if pk == s.OwnerHex {
		return StateFirst
	}
	npub := npubOfHex(pk)
	if npub == "" {
		return StateNone
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state := StateNone
	for _, a := range LoadAccounts(s.Path) {
		if a.Npub != npub {
			continue
		}
		if a.SignedIn {
			return StateSignedIn
		}
		state = StateWatchOnly
	}
	return state
}

// List: the first account, then the added ones in the order they were added.
func (s *AccountStore) List() []AccountView {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []AccountView{{Npub: s.OwnerNpub, State: StateFirst}}
	saved := LoadAccounts(s.Path)
	lists := ListsFor(s.OwnerNpub, saved)
	byNpub := map[string]Account{}
	for _, a := range saved {
		prev, seen := byNpub[a.Npub]
		if seen {
			a.SignedIn = a.SignedIn || prev.SignedIn
			if a.Name == "" {
				a.Name = prev.Name
			}
		}
		byNpub[a.Npub] = a
	}
	for _, n := range lists.Accounts[1:] {
		a := byNpub[n]
		state := StateWatchOnly
		if a.SignedIn {
			state = StateSignedIn
		}
		out = append(out, AccountView{Npub: n, State: state, Added: a.Added, Name: a.Name})
	}
	return out
}

// change runs f on the saved list under the lock and saves what it returns.
// A damaged file is reported, never overwritten.
func (s *AccountStore) change(f func([]Account) ([]Account, error)) error {
	s.mu.Lock()
	accounts, err := ReadAccounts(s.Path)
	if err == nil {
		accounts, err = f(accounts)
	}
	if err == nil {
		err = SaveAccounts(s.Path, accounts)
	}
	s.mu.Unlock()
	if err == nil && s.Changed != nil {
		s.Changed()
	}
	return err
}

// AddWatchOnly adds npub (npub or hex) as a watch-only account: the box
// keeps its notes and files and shows it nothing private. It becomes signed
// in only by joining with a code (Join): a public key proves nothing about
// who holds it, and on a Mac an account added by npub alone is often
// someone else's (Logen, PR #1971).
func (s *AccountStore) AddWatchOnly(npub, name string) (AccountView, error) {
	pk, npub, err := ParseOwner(npub)
	if err != nil {
		return AccountView{}, err
	}
	if pk == s.OwnerHex {
		return AccountView{}, ErrFirstAccount
	}
	a := Account{Npub: npub, Added: s.Now().Unix(), Name: cleanName(name)}
	err = s.change(func(in []Account) ([]Account, error) {
		for _, x := range in {
			if x.Npub == npub {
				return nil, ErrAccountExists
			}
		}
		return append(in, a), nil
	})
	return AccountView{Npub: npub, State: StateWatchOnly, Added: a.Added, Name: a.Name}, err
}

// Join makes pk (hex, whose own signature the caller has checked) a
// signed-in account: added if new, promoted if watch-only. The caller has
// already taken a valid one-time code (JoinCodes.Redeem).
func (s *AccountStore) Join(pk, name string) (AccountView, error) {
	pk = strings.ToLower(pk)
	if pk == s.OwnerHex {
		return AccountView{}, ErrFirstAccount
	}
	npub := npubOfHex(pk)
	if npub == "" {
		return AccountView{}, errors.New("not a public key")
	}
	name = cleanName(name)
	view := AccountView{Npub: npub, State: StateSignedIn}
	err := s.change(func(in []Account) ([]Account, error) {
		found := false
		for i := range in {
			if in[i].Npub != npub {
				continue
			}
			found = true
			in[i].SignedIn = true
			if name != "" {
				in[i].Name = name
			}
			view.Added, view.Name = in[i].Added, in[i].Name
		}
		if !found {
			view.Added, view.Name = s.Now().Unix(), name
			in = append(in, Account{Npub: npub, Added: view.Added, SignedIn: true, Name: name})
		}
		return in, nil
	})
	return view, err
}

// Remove drops npub from the box. Its notes and files stay in the vault, as
// on a Mac; adding it again shows them again.
func (s *AccountStore) Remove(npub string) error {
	pk, npub, err := ParseOwner(npub)
	if err != nil {
		return err
	}
	if pk == s.OwnerHex {
		return ErrFirstAccount
	}
	return s.change(func(in []Account) ([]Account, error) {
		out := in[:0]
		for _, a := range in {
			if a.Npub != npub {
				out = append(out, a)
			}
		}
		if len(out) == len(in) {
			return nil, ErrNoAccount
		}
		return out, nil
	})
}

// cleanName: a label, at most 64 characters, no control characters.
func cleanName(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if r := []rune(s); len(r) > 64 {
		s = string(r[:64])
	}
	return strings.TrimSpace(s)
}
