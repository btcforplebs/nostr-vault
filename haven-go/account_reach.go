package main

import (
	"encoding/json"
	"log"
	"os"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// account_reach.json is each account's own Follow Distance, written by the
// host app next to the relay's other files (ACCOUNT_REACH_FILE):
//
//	{"v": 1, "accounts": {"npub1…": {"depth": 2, "min_followers": 3}}}
//
// An account with no entry uses the vault's single value (WOT_DEPTH,
// WOT_MINIMUM_FOLLOWERS), so a host that writes no file, an older app, the
// box and the browser all behave as before. It is read once per config load:
// changing it means restarting the relay, like changing WOT_DEPTH.
type accountReachFile struct {
	V        int `json:"v"`
	Accounts map[string]struct {
		Depth        int `json:"depth"`
		MinFollowers int `json:"min_followers"`
	} `json:"accounts"`
}

// reachByAccount is the file as the relay holds it: hex pubkey to that
// account's own Follow Distance.
type reachByAccount = map[string]wot.AccountReach

// accountReachFileVersion is the only "v" read; another one means a shape
// this build does not know, so no account gets an entry from it.
const accountReachFileVersion = 1

// loadAccountReach reads the file into a map keyed by hex pubkey. A missing
// file is the normal case and means no entries; an unreadable one is logged
// and also means no entries. A level outside 1-3 is pulled to the nearest
// (level 0, a public relay, is only ever WOT_DEPTH=0); a negative Min
// Followers is 0.
func loadAccountReach(filePath string) reachByAccount {
	reach := reachByAccount{}
	if filePath == "" {
		return reach
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("⚠️ Failed to read account reach file %s: %s", filePath, err)
		}
		return reach
	}
	var file accountReachFile
	if err := json.Unmarshal(data, &file); err != nil {
		log.Printf("⚠️ Failed to parse account reach file %s: %s", filePath, err)
		return reach
	}
	if file.V != accountReachFileVersion {
		log.Printf("⚠️ Account reach file %s is version %d, not %d: ignored", filePath, file.V, accountReachFileVersion)
		return reach
	}
	for npub, entry := range file.Accounts {
		pk := nPubToPubkey(filePath, npub)
		if pk == "" {
			continue
		}
		reach[pk] = wot.AccountReach{
			Depth:        min(max(entry.Depth, 1), 3),
			MinFollowers: max(entry.MinFollowers, 0),
		}
	}
	return reach
}

// accountReach is owner's own Follow Distance from the file, and false when
// it has no entry.
func accountReach(owner string) (wot.AccountReach, bool) {
	reach, ok := config.AccountReach[owner]
	return reach, ok
}

// firstRunAccountReach is accountReach while the first-run flow holds the
// web to the follows (effectiveWotDepth): an account's own level 3 waits for
// the wider_network job too.
func firstRunAccountReach(owner string) (wot.AccountReach, bool) {
	reach, ok := accountReach(owner)
	if ok {
		reach.Depth = effectiveDepthFor(reach.Depth)
	}
	return reach, ok
}

// newWotModel is wot.NewSimpleInMemory with each account's own Follow
// Distance wired in. Every web the relay builds goes through it or
// newFirstRunWotModel, so no build falls back to one level for all accounts.
func newWotModel(pool *nostr.SimplePool, whitelistedPubKeys map[string]struct{}, seedRelays []string, wotDepth int, minFollowers int, wotFetchTimeout int, cachePath string, cacheTTLMinutes int) *wot.SimpleInMemory {
	model := wot.NewSimpleInMemory(pool, whitelistedPubKeys, seedRelays, wotDepth, minFollowers, wotFetchTimeout, cachePath, cacheTTLMinutes)
	model.ReachFor = accountReach
	return model
}

// newFirstRunWotModel is newWotModel for the builds that pass
// effectiveWotDepth(): the relay's own start and the rebuild with the vault
// on an outside relay.
func newFirstRunWotModel(pool *nostr.SimplePool, whitelistedPubKeys map[string]struct{}, seedRelays []string, wotDepth int, minFollowers int, wotFetchTimeout int, cachePath string, cacheTTLMinutes int) *wot.SimpleInMemory {
	model := newWotModel(pool, whitelistedPubKeys, seedRelays, wotDepth, minFollowers, wotFetchTimeout, cachePath, cacheTTLMinutes)
	model.ReachFor = firstRunAccountReach
	return model
}
