package main

import (
	"context"
	"slices"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Every gate asks "may this person reach this account", never "is this
// person in the vault's web": each account's web comes from its own follows
// at its own Follow Distance (pkg/wot HasFor), and one account's follows get
// nobody through to another.

// taggedAccounts is the vault's own accounts ev p-tags, in tag order, each
// once.
func taggedAccounts(ev *nostr.Event) []string {
	var accounts []string
	own := whitelist()
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) < 2 {
			continue
		}
		if _, ok := own[tag[1]]; !ok {
			continue
		}
		if !slices.Contains(accounts, tag[1]) {
			accounts = append(accounts, tag[1])
		}
	}
	return accounts
}

// inAccountsWeb reports whether pubkey is in account's own web. The vault's
// own accounts are in every account's web, at every level, whether or not
// the account follows them (Logen, 2026-11-22); the model says so too, and
// saying it here keeps the rule whatever model is installed.
func inAccountsWeb(ctx context.Context, account, pubkey string) bool {
	return isOwnKey(pubkey) || wot.HasFor(ctx, account, pubkey)
}

// accountAdmits reports whether account lets ev in from pubkey: pubkey is in
// that account's own web, or ev answers or quotes a post that account wrote
// (anyone may reply to you: a stranger answering you is news, where a
// stranger merely tagging you is the spam the web keeps out).
func accountAdmits(ctx context.Context, account, pubkey string, ev *nostr.Event) bool {
	return inAccountsWeb(ctx, account, pubkey) || engagesPostBy(ctx, ev, map[string]struct{}{account: {}})
}

// admittingAccounts is the accounts among tagged that let ev in from pubkey,
// in the same order.
func admittingAccounts(ctx context.Context, tagged []string, pubkey string, ev *nostr.Event) []string {
	var admitted []string
	for _, account := range tagged {
		if accountAdmits(ctx, account, pubkey, ev) {
			admitted = append(admitted, account)
		}
	}
	return admitted
}

// inAnyAccountsWeb reports whether pubkey is in the web of at least one of
// the vault's accounts. Only for the questions that name no account: a read
// of the chat relay, an event that tags none of them, and the recheck of a
// remembered rejection (which is then judged again per account).
func inAnyAccountsWeb(ctx context.Context, pubkey string) bool {
	for account := range whitelist() {
		if inAccountsWeb(ctx, account, pubkey) {
			return true
		}
	}
	return false
}
