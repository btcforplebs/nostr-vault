package trustrank

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// ResultBuiltAt is the builtAt of account's result file in dir, read from
// the start of the file: a request that only asks "is there anything newer"
// does not decode every row. The writer puts account and builtAt before
// people; a file that does not (written some other way) is read whole.
func ResultBuiltAt(dir, account string) (int64, error) {
	if !validAccount(account) {
		return 0, ErrBadResult
	}
	fh, err := os.Open(ResultPath(dir, account))
	if err != nil {
		return 0, err
	}
	defer fh.Close()
	dec := json.NewDecoder(fh)
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return 0, ErrBadResult
	}
	var acct string
	var built int64
	haveAcct, haveBuilt := false, false
	for dec.More() {
		if haveAcct && haveBuilt {
			break
		}
		t, err := dec.Token()
		if err != nil {
			return 0, ErrBadResult
		}
		key, _ := t.(string)
		switch key {
		case "account":
			haveAcct = dec.Decode(&acct) == nil
		case "builtAt":
			haveBuilt = dec.Decode(&built) == nil
		default:
			var skip json.RawMessage
			if dec.Decode(&skip) != nil {
				return 0, ErrBadResult
			}
		}
	}
	if !haveAcct || !haveBuilt || acct != account || built <= 0 {
		return 0, ErrBadResult
	}
	return built, nil
}

// PruneAccounts removes the result file and crawl checkpoint of every
// account in dir that is not in keep (signed out), and says which. The
// list store (wot_deep) is shared by all accounts and stays.
func PruneAccounts(dir string, keep []string) []string {
	kept := map[string]bool{}
	for _, a := range keep {
		kept[a] = true
	}
	var gone []string
	for _, pattern := range []string{"wot_rank_*.json", "state_*.json"} {
		paths, _ := filepath.Glob(filepath.Join(dir, pattern))
		for _, p := range paths {
			name := filepath.Base(p)
			prefix := strings.TrimSuffix(pattern, "*.json")
			account := strings.TrimSuffix(strings.TrimPrefix(name, prefix), ".json")
			if !validAccount(account) || kept[account] {
				continue
			}
			if err := os.Remove(p); err == nil || errors.Is(err, os.ErrNotExist) {
				if prefix == "wot_rank_" {
					gone = append(gone, account)
				}
			}
		}
	}
	return gone
}
