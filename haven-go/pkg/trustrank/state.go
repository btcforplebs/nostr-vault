package trustrank

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// State is one account's crawl checkpoint (state_<account>.json): where the
// crawl is, so a restart, a pause or a closed window picks up at the next
// list.
type State struct {
	Account string `json:"account"`
	// Version of the weights the last rank used; a change starts the pass
	// again at hop 1.
	ParamsVersion int `json:"paramsVersion"`
	// Hop being read (1 = the owner's follows' lists).
	Hop int `json:"hop"`
	// Place in that hop's reader list (progress only).
	Next int `json:"next"`
	// Last pubkey whose list was read in this hop; a resume goes on at the
	// first reader after it.
	Last string `json:"last,omitempty"`
	// Refresh: the pass in progress asks only for newer lists.
	Refresh bool `json:"refresh,omitempty"`
	// Capped: the last pass stopped at the store cap (not a finished pass).
	Capped bool `json:"capped,omitempty"`
	// Unix seconds: last finished full pass, last daily refresh.
	FullAt    int64 `json:"fullAt,omitempty"`
	RefreshAt int64 `json:"refreshAt,omitempty"`
	// Unix seconds: when the pass in progress started reading (kept through
	// a pause or restart), and when the last finished pass started. A
	// refresh asks for lists from DoneStart less a day: a pass can run for
	// days, and someone read early in it may have changed their list since.
	PassStart int64 `json:"passStart,omitempty"`
	DoneStart int64 `json:"doneStart,omitempty"`
}

// validAccount: an account is a 64-character hex pubkey, so it can never
// name a path outside dir.
func validAccount(account string) bool {
	if len(account) != 64 {
		return false
	}
	_, err := hex.DecodeString(account)
	return err == nil
}

// StatePath is the checkpoint's file for account in dir. Callers check the
// account with validAccount first (LoadState and SaveState do).
func StatePath(dir, account string) string {
	return filepath.Join(dir, "state_"+account+".json")
}

// LoadState reads the checkpoint; a missing or unreadable one starts over.
func LoadState(dir, account string) State {
	var st State
	if !validAccount(account) {
		return State{Account: account}
	}
	b, err := os.ReadFile(StatePath(dir, account))
	if err != nil || json.Unmarshal(b, &st) != nil || st.Account != account {
		return State{Account: account}
	}
	return st
}

// SaveState writes the checkpoint through a temp file and a rename, so a
// reader never sees half of it. While a Store is being filled, use
// Store.Checkpoint instead: it syncs the lists first, so the checkpoint
// never claims a list the disk does not hold yet.
func SaveState(dir string, st State) error {
	if !validAccount(st.Account) {
		return fmt.Errorf("trustrank: %q is not a hex pubkey", st.Account)
	}
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	path := StatePath(dir, st.Account)
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}
