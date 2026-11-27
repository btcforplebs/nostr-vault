package main

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"time"
)

// copyRemovedHereFile: the files the owner took off this device with "Delete
// from this device", by account (hex pubkey). The app writes it in the relay
// data folder (Android DeviceRemovedHashes.kt); the copy v2 catch-up leaves
// these on the other device instead of pulling them back. Save to Vault in
// the app takes a hash off. Shape: {"byAccount":{"<hex>":["<sha256>",…]}}.
const copyRemovedHereFile = "removed_here.json"

var copyRemovedHere = struct {
	sync.Mutex
	mod  time.Time
	size int64
	set  map[string]bool // lower-case sha
}{}

// copyIsRemovedHere: whether the owner removed sha from this device, under
// any account: the vault folder holds one file per hash whoever's record
// listed it, so a copy for another account would put the same file back.
// The file is read again only when it changed. An unreadable file keeps the last
// list read, so a half-written file cannot let everything back in.
func copyIsRemovedHere(sha string) bool {
	copyRemovedHere.Lock()
	defer copyRemovedHere.Unlock()
	st, err := os.Stat(copyRemovedHereFile)
	if err != nil {
		if os.IsNotExist(err) {
			copyRemovedHere.set, copyRemovedHere.mod, copyRemovedHere.size = nil, time.Time{}, 0
		}
		return copyRemovedHere.set[strings.ToLower(sha)]
	}
	if copyRemovedHere.set == nil || !st.ModTime().Equal(copyRemovedHere.mod) || st.Size() != copyRemovedHere.size {
		if set, ok := readCopyRemovedHere(); ok {
			copyRemovedHere.set, copyRemovedHere.mod, copyRemovedHere.size = set, st.ModTime(), st.Size()
		}
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
