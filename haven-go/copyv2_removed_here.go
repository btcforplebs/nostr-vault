package main

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
)

// copyRemovedHereFile: the files the owner took off this device with "Delete
// from this device", by account (hex pubkey). The app writes it in the relay
// data folder (Android DeviceRemovedHashes.kt); the copy v2 catch-up leaves
// these on the other device instead of pulling them back. Save to Vault in
// the app takes a hash off. Shape: {"byAccount":{"<hex>":["<sha256>",…]}}.
const copyRemovedHereFile = "removed_here.json"

var copyRemovedHere = struct {
	sync.Mutex
	set map[string]bool // lower-case sha
}{}

// copyIsRemovedHere: whether the owner removed sha from this device, under
// any account: the vault folder holds one file per hash whoever's record
// listed it, so a copy for another account would put the same file back.
// The file is read on every call: it is tiny, and a change inside one coarse
// mtime tick that keeps its size (an allow plus a remove) must not be missed
// (Tron, #2649). An unreadable file keeps the last list read, so a
// half-written file cannot let everything back in.
func copyIsRemovedHere(sha string) bool {
	copyRemovedHere.Lock()
	defer copyRemovedHere.Unlock()
	if _, err := os.Stat(copyRemovedHereFile); os.IsNotExist(err) {
		copyRemovedHere.set = nil
	} else if set, ok := readCopyRemovedHere(); ok {
		copyRemovedHere.set = set
	}
	return copyRemovedHere.set[strings.ToLower(sha)]
}

func readCopyRemovedHere() (map[string]bool, bool) {
	raw, err := os.ReadFile(copyRemovedHereFile)
	if err != nil {
		return nil, false
	}
	var disk struct {
		ByAccount map[string][]string `json:"byAccount"`
	}
	if json.Unmarshal(raw, &disk) != nil {
		return nil, false
	}
	set := map[string]bool{}
	for _, hashes := range disk.ByAccount {
		for _, sha := range hashes {
			set[strings.ToLower(sha)] = true
		}
	}
	return set, true
}
