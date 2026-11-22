package box

import (
	"context"
	"log"
	"slices"
	"sync"
	"time"
)

// A box holds several accounts, all of them the owner's, like a Mac (One
// Vault addendum A.3). The first account is box/owner (or NV_OWNER): it
// claimed the box and runs it. Every other account is an added account,
// saved in box/accounts.json (accounts_file.go), outside the vault folder so
// Move never touches it.
//
// An added account is in one of two states, the same two a Mac account has:
//
//   - watch-only: the box keeps its notes and files (it is on the engine's
//     account list) but shows nothing private to anyone signed in as it;
//   - signed in: it has proved it holds its key by signing to the box with
//     its own signer, and reads the private side like the first account.
//
// The engine gets two lists (EngineLists): every account, and the private
// readers. The private-reader list is always named: an engine given no
// PRIVATE_READER_NPUBS_FILE lets every listed account read everything
// (haven-go config.go privateReadersFromFile), which would make a
// watch-only account a reader.

// Account is one added account in box/accounts.json.
type Account struct {
	// Npub is the account's public key. Never a secret key: a file entry
	// that is not a valid npub (or hex pubkey) is dropped on read.
	Npub string `json:"npub"`
	// Added is when the first account added it (Unix seconds).
	Added int64 `json:"added"`
	// SignedIn: it has signed to this box with its own signer at least once.
	SignedIn bool `json:"signedIn"`
	// Name is an optional label the first account gave it.
	Name string `json:"name,omitempty"`
}

// EngineLists are the two npub lists the engine reads from the vault folder:
// Accounts (whitelisted_npubs.json, space for notes and files) and Readers
// (private_reader_npubs.json, reads the private side). The first account
// leads both. Readers is always a subset of Accounts.
type EngineLists struct {
	Accounts []string
	Readers  []string
}

// ListsFor: the engine's lists for first account ownerNpub plus added.
// Entries naming the first account again, or naming one key twice, count
// once; a repeat never turns a watch-only account into a reader unless one
// of its entries says signed in.
func ListsFor(ownerNpub string, added []Account) EngineLists {
	l := EngineLists{Accounts: []string{ownerNpub}, Readers: []string{ownerNpub}}
	seen := map[string]bool{ownerNpub: true}
	reader := map[string]bool{}
	for _, a := range added {
		if !seen[a.Npub] {
			seen[a.Npub] = true
			l.Accounts = append(l.Accounts, a.Npub)
		}
		if a.SignedIn {
			reader[a.Npub] = true
		}
	}
	// Readers in Accounts order, so the files are stable across reads.
	for _, n := range l.Accounts[1:] {
		if reader[n] {
			l.Readers = append(l.Readers, n)
		}
	}
	return l
}

func (l EngineLists) equal(o EngineLists) bool {
	return slices.Equal(l.Accounts, o.Accounts) && slices.Equal(l.Readers, o.Readers)
}

// Reloader restarts the engine so it reads its lists again (Engine.Reload).
type Reloader interface{ Reload() bool }

// AccountsWatch keeps the engine's lists in step with box/accounts.json.
// The engine reads its account lists only when it starts and cannot drop an
// account live (A.1), so a change means a restart. The engine's Prepare
// (WriteEngineFiles) writes the lists on every start; Run only notices the
// change and asks for the restart.
type AccountsWatch struct {
	Config Config
	Engine Reloader

	mu   sync.Mutex // Run's ticks and AccountStore.Changed both call Check
	last EngineLists
	have bool
}

// Seed records the lists as they are now, without reloading. Call it before
// the engine first starts (havend does): its Prepare then writes these lists
// or newer ones, so a change made after Seed is a change the next Check sees.
// Seeding later would let a join or hand edit made in between become the
// baseline, and that account would not reach the engine until a restart
// (Tron #2374). A change between Seed and the engine's start costs one extra
// reload, never a missed one.
func (w *AccountsWatch) Seed() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.seed()
}

func (w *AccountsWatch) seed() {
	w.last, w.have = ListsFor(w.Config.OwnerNpub, LoadAccounts(w.Config.AccountsFile())), true
}

// Check reads accounts.json and reloads the engine if its lists changed
// since Seed or the last Check. Without a Seed, the first Check only records
// them. Reports whether it asked for a reload.
func (w *AccountsWatch) Check() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.have {
		w.seed()
		return false
	}
	now := ListsFor(w.Config.OwnerNpub, LoadAccounts(w.Config.AccountsFile()))
	if now.equal(w.last) {
		return false
	}
	w.last = now
	log.Printf("box: accounts changed (%d accounts, %d private readers); restarting the vault engine", len(now.Accounts), len(now.Readers))
	if !w.Engine.Reload() {
		// Stopped (a Move is running): its next Start writes the new lists.
		log.Printf("box: vault engine not running; the new account lists apply on its next start")
	}
	return true
}

// Run calls Check every interval until ctx ends.
func (w *AccountsWatch) Run(ctx context.Context, every time.Duration) {
	w.Check()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.Check()
		}
	}
}
