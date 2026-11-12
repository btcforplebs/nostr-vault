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

// privateReaders: the keys that may read the vault's private side: /private,
// list history, the full blob list and unposted blobs over the mesh. The
// owner plus the accounts with a key or signer on this device
// (PRIVATE_READER_NPUBS_FILE, written by the app). Every other added account
// has space for its own notes and uploads (whitelist()) and reads nothing
// gated (Logen, 2026-11-12, PR #1971): an added npub is often someone else's,
// and whoever holds its nsec could AUTH as it. With no file named, the
// whitelist (see privateReadersFromFile). Live additions (AddAccountsC) never
// read: they are brought-over, watch-only accounts.
func privateReaders() map[string]struct{} {
	if r := config.PrivateReaderPubKeys; r != nil {
		return r
	}
	return whitelist()
}

// isPrivateReader: pk is a private reader and still one of the vault's own.
func isPrivateReader(pk string) bool {
	if _, ok := privateReaders()[pk]; !ok {
		return false
	}
	return isOwnKey(pk)
}

func isOwnKey(pk string) bool {
	_, ok := whitelist()[pk]
	return ok
}

// addLiveAccounts makes the given hex keys the vault's own now, for every
// check that reads whitelist(): restore, import, inbox, uploads. Returns how
// many were new.
func addLiveAccounts(hexes []string) int {
	return len(addLiveAccountsNew(hexes))
}

// addLiveAccountsNew is addLiveAccounts returning the keys that were new.
func addLiveAccountsNew(hexes []string) []string {
	liveWLMu.Lock()
	defer liveWLMu.Unlock()
	base := config.WhitelistedPubKeys
	extra := map[string]struct{}{}
	if l := liveWL.Load(); l != nil && l.base == mapID(base) {
		maps.Copy(extra, l.extra)
	}
	var added []string
	for _, h := range hexes {
		if _, own := base[h]; own {
			continue
		}
		if _, have := extra[h]; have {
			continue
		}
		extra[h] = struct{}{}
		added = append(added, h)
	}
	storeLiveAccounts(base, extra)
	return added
}

func storeLiveAccounts(base, extra map[string]struct{}) {
	merged := make(map[string]struct{}, len(base)+len(extra))
	maps.Copy(merged, base)
	maps.Copy(merged, extra)
	liveWL.Store(&liveWhitelist{base: mapID(base), extra: extra, merged: merged})
}

// resetLiveAccounts: a new config is the app's word on its accounts again
// (a removed account must stop being one). Called by every loadConfig.
func resetLiveAccounts() {
	liveWLMu.Lock()
	liveWL.Store(nil)
	liveWLMu.Unlock()
}
