package trustrank

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// State is one account's crawl checkpoint (state_<account>.json): where the
// crawl is, so a restart, a pause or a closed window picks up at the next
// list.
type State struct {
	Account string `json:"account"`
	// Version of the weights the last rank used; a change re-ranks from the
	// stored lists without downloading again.
	ParamsVersion int `json:"paramsVersion"`
	// Hop being read (1 = the owner's follows' lists).
	Hop int `json:"hop"`
	// Place in that hop's reader list.
	Next int `json:"next"`
	// Unix seconds: last finished full pass, last daily refresh.
	FullAt    int64 `json:"fullAt,omitempty"`
	RefreshAt int64 `json:"refreshAt,omitempty"`
}

// StatePath is the checkpoint's file for account in dir.
func StatePath(dir, account string) string {
	return filepath.Join(dir, "state_"+account+".json")
}

// LoadState reads the checkpoint; a missing or unreadable one starts over.
func LoadState(dir, account string) State {
	var st State
	b, err := os.ReadFile(StatePath(dir, account))
	if err != nil || json.Unmarshal(b, &st) != nil || st.Account != account {
		return State{Account: account}
	}
	return st
}

// SaveState writes the checkpoint through a temp file and a rename, so a
// reader never sees half of it.
func SaveState(dir string, st State) error {
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
