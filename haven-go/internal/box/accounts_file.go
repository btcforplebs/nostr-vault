package box

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// box/accounts.json: the box's added accounts (accounts.go). No file reads
// as no added accounts, so a box from before accounts behaves exactly as it
// did: the first account alone.

// AccountsFile is box/accounts.json.
func (c Config) AccountsFile() string { return filepath.Join(c.BoxDir(), "accounts.json") }

// LoadAccounts reads the added accounts in path. It fails closed: a missing
// file is no added accounts; an unreadable or unparsable one is logged and
// also read as none, so the engine falls back to the first account alone
// (added accounts lose access until the file is fixed; their notes and files
// stay). Entries that are not a valid npub or hex pubkey (an nsec included)
// are dropped, and every kept Npub is the canonical npub1 form.
func LoadAccounts(path string) []Account {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		log.Printf("box: reading %s: %v; holding the first account only", path, err)
		return nil
	}
	var in []Account
	if err := json.Unmarshal(raw, &in); err != nil {
		log.Printf("box: %s is not an account list: %v; holding the first account only", path, err)
		return nil
	}
	out := make([]Account, 0, len(in))
	for i, a := range in {
		_, npub, err := ParseOwner(a.Npub)
		if err != nil {
			log.Printf("box: %s entry %d dropped: %v", path, i, strings.Replace(err.Error(), "NV_OWNER", "npub", 1))
			continue
		}
		a.Npub = npub
		out = append(out, a)
	}
	return out
}

// SaveAccounts writes accounts to path atomically (temp file, then rename),
// owner-only (0600), creating box/ if needed.
func SaveAccounts(path string, accounts []Account) error {
	if accounts == nil {
		accounts = []Account{}
	}
	b, err := json.MarshalIndent(accounts, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".accounts-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return fmt.Errorf("writing %s: %w", path, err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
