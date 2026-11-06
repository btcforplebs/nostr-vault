package main

import (
	"maps"
	"reflect"
	"sync"
	"sync/atomic"
)

// The vault's own keys: the owner and every added account
// (config.WhitelistedPubKeys, read once per relay start), plus accounts added
// live, without a restart, by AddAccountsC or a copy from another of the
// owner's devices (docs/MESH_COPY_V2_CONTRACT.md §3, accounts).
//
// config.WhitelistedPubKeys is never written after loadConfig, so readers need
// no lock. Live additions are a separate copy-on-write set; whitelist() hands
// out one merged map that is never written after it is published.

type liveWhitelist struct {
	base   uintptr             // config.WhitelistedPubKeys this was merged with
	extra  map[string]struct{} // live additions (hex)
	merged map[string]struct{} // base + extra; nil when extra is empty
}

var (
	liveWL   atomic.Pointer[liveWhitelist]
	liveWLMu sync.Mutex // serializes writers; readers are lock-free
)

func mapID(m map[string]struct{}) uintptr { return reflect.ValueOf(m).Pointer() }

// whitelist: every key that is one of this vault's own. Read-only.
func whitelist() map[string]struct{} {
	base := config.WhitelistedPubKeys
	l := liveWL.Load()
	if l == nil || len(l.extra) == 0 {
		return base
	}
	if l.base != mapID(base) {
		// A config replaced without loadConfig (tests): its additions were
		// made to the old one and do not carry over.
		return base
	}
	return l.merged
}

func isOwnKey(pk string) bool {
	_, ok := whitelist()[pk]
	return ok
}

// addLiveAccounts makes the given hex keys the vault's own now, for every
// check that reads whitelist(): restore, import, inbox, uploads. Returns how
// many were new.
func addLiveAccounts(hexes []string) int {
	liveWLMu.Lock()
	defer liveWLMu.Unlock()
	base := config.WhitelistedPubKeys
	extra := map[string]struct{}{}
	if l := liveWL.Load(); l != nil && l.base == mapID(base) {
		maps.Copy(extra, l.extra)
	}
	added := 0
	for _, h := range hexes {
		if _, own := base[h]; own {
			continue
		}
		if _, have := extra[h]; have {
			continue
		}
		extra[h] = struct{}{}
		added++
	}
	merged := make(map[string]struct{}, len(base)+len(extra))
	maps.Copy(merged, base)
	maps.Copy(merged, extra)
	liveWL.Store(&liveWhitelist{base: mapID(base), extra: extra, merged: merged})
	return added
}

// resetLiveAccounts: a new config is the app's word on its accounts again
// (a removed account must stop being one). Called by every loadConfig.
func resetLiveAccounts() {
	liveWLMu.Lock()
	liveWL.Store(nil)
	liveWLMu.Unlock()
}
