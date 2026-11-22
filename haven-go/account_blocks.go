package main

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"sync/atomic"

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
)

// Each account has its own block list: its public blocks and private mutes,
// and nobody else's. A block on account A keeps that person out of A and
// hides them from A's reads; it does nothing to account B.
//
// The host gives the whole map each time, at start through
// BLOCKS_BY_ACCOUNT_FILE and live through UpdateAccountBlocks:
//
//	{"v": 1, "accounts": {"npub1account…": ["npub1blocked…", …]}}
//
// The older vault-wide list (BLACKLISTED_NPUBS_FILE, UpdateBlacklist) stays
// for hosts that still send it, and applies to every account.
//
// You cannot block your own accounts: one of the vault's own keys is never
// blocked, whoever's list names it (Logen, 2026-11-22).

// blocksByAccount is account hex → the hex pubkeys it blocks.
type blocksByAccount = map[string]map[string]struct{}

const accountBlocksVersion = 1

// accountBlocksOverride is the live map (UpdateAccountBlocks), swapped whole
// like the blacklist: read on every tagged event, written rarely.
var accountBlocksOverride atomic.Pointer[blocksByAccount]

// accountBlocks is the live map when one was pushed, else the one read at
// start. Nil: the host gave none.
func accountBlocks() blocksByAccount {
	if m := accountBlocksOverride.Load(); m != nil {
		return *m
	}
	return config.AccountBlocks
}

// parseAccountBlocks reads the map from its JSON. A bad npub is skipped; a
// shape or version this build does not know is an error.
func parseAccountBlocks(data []byte) (blocksByAccount, error) {
	var file struct {
		V        int                 `json:"v"`
		Accounts map[string][]string `json:"accounts"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, err
	}
	if file.V != accountBlocksVersion {
		return nil, errors.New("unknown version")
	}
	blocks := make(blocksByAccount, len(file.Accounts))
	for npub, blocked := range file.Accounts {
		account := nPubToPubkey("account blocks", npub)
		if account == "" {
			continue
		}
		set := make(map[string]struct{}, len(blocked))
		for _, b := range blocked {
			if pk := nPubToPubkey("account blocks", b); pk != "" {
				set[pk] = struct{}{}
			}
		}
		blocks[account] = set
	}
	return blocks, nil
}

// loadAccountBlocks reads the start-up file. No file is the normal case for
// a host that does not write one, and means none (nil), like a file that
// cannot be read.
func loadAccountBlocks(filePath string) blocksByAccount {
	if filePath == "" {
		return nil
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("⚠️ Failed to read account blocks file %s: %s", filePath, err)
		}
		return nil
	}
	blocks, err := parseAccountBlocks(data)
	if err != nil {
		log.Printf("⚠️ Account blocks file %s ignored: %s", filePath, err)
		return nil
	}
	return blocks
}

// UpdateAccountBlocks replaces every account's block list at once. It takes
// effect on the next event and the next read, with no relay restart, and
// the account webs are counted again in the background, since a blocked
// follow vouches for nobody.
func UpdateAccountBlocks(blocks blocksByAccount) {
	accountBlocksOverride.Store(&blocks)
	retallyAccountWebs()
}

// retallyAccountWebs counts the account webs again after a block change.
func retallyAccountWebs() {
	if model, ok := wot.GetInstance().(interface{ RetallyAccounts() }); ok {
		runsafe.Go("wot.RetallyAccounts", model.RetallyAccounts)
	}
}

// blockedBy reports whether account has blocked pubkey: it is on that
// account's own list, or on the vault-wide one. Never one of your own
// accounts: that check comes first.
func blockedBy(account, pubkey string) bool {
	if isOwnKey(pubkey) {
		return false
	}
	if isBlacklisted(pubkey) {
		return true
	}
	_, blocked := accountBlocks()[account][pubkey]
	return blocked
}

// blockedByAll reports whether every one of accounts has blocked pubkey.
// False for no accounts.
func blockedByAll(accounts []string, pubkey string) bool {
	if len(accounts) == 0 {
		return false
	}
	for _, account := range accounts {
		if !blockedBy(account, pubkey) {
			return false
		}
	}
	return true
}
