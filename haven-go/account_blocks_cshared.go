//go:build cshared

package main

import "C"

import "log"

// UpdateAccountBlocksC replaces every account's block list (account_blocks.go):
// {"v":1,"accounts":{"npub1account…":["npub1blocked…"]}}, the whole map each
// time. Called when any account blocks, unblocks, mutes or unmutes someone.
// Returns how many accounts the map names, or -1 when the JSON is refused
// (nothing changes then).
//
//export UpdateAccountBlocksC
func UpdateAccountBlocksC(blocksJSON *C.char) C.int {
	blocks, err := parseAccountBlocks([]byte(C.GoString(blocksJSON)))
	if err != nil {
		log.Printf("⚠️ UpdateAccountBlocksC: refused: %v", err)
		return -1
	}
	UpdateAccountBlocks(blocks)
	log.Printf("🚷 Live account blocks updated: %d account(s)", len(blocks))
	return C.int(len(blocks))
}
