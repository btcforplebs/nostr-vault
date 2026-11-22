package main

import (
	"context"
	"log/slog"
	"slices"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Every gate asks "may this person reach this account", never "is this
// person in the vault's web": each account's web comes from its own follows
// at its own Follow Distance (pkg/wot HasFor).
//
// What that decides today: whether an event is kept at all (at least one
// tagged account must let it in), and which accounts it is notified and
// listed for (recipients). It does not yet decide what a read returns: an
// event kept for account A that also tags B is stored once in the shared
// inbox, and a `#p` read for B still returns it. The per-account filter on
// inbox reads comes with the per-account blocks (scoped reads, step E3).

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

// accountAdmits reports whether account lets ev in from pubkey: account has
// not blocked pubkey, and pubkey is in that account's own web, or ev answers
// or quotes a post that account wrote (anyone may reply to you: a stranger
// answering you is news, where a stranger merely tagging you is the spam the
// web keeps out).
func accountAdmits(ctx context.Context, account, pubkey string, ev *nostr.Event) bool {
	if blockedBy(account, pubkey) {
		return false
	}
	return inAccountsWeb(ctx, account, pubkey) || engagesPostBy(ctx, ev, map[string]struct{}{account: {}})
}

// reachesAccount is accountAdmits without an event: account has not blocked
// pubkey and holds it in its web.
func reachesAccount(ctx context.Context, account, pubkey string) bool {
	return !blockedBy(account, pubkey) && inAccountsWeb(ctx, account, pubkey)
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

// inboxRecipients is the accounts a tagged event is kept for, or why it is
// not kept at all. Each tagged account judges the author (trustKey: the
// zapper for a zap receipt) by its own blocks and its own web, and the event
// is kept for the accounts that let it in. A gift wrap's author is a
// throwaway key, so it is kept for every account it tags.
func inboxRecipients(ctx context.Context, ev *nostr.Event, trustKey string) ([]string, rejectReason) {
	recipients := taggedAccounts(ev)
	// When every tagged account has blocked the author it is a block
	// rejection; when only some have, the event is kept for the others
	// (accountAdmits leaves the blocking ones out).
	if blockedByAll(recipients, trustKey) || blockedByAll(recipients, ev.PubKey) {
		slog.Debug("🚫discarding imported note from a pubkey every tagged account blocked", "pubkey", trustKey, "id", ev.ID)
		return nil, rejectBlacklist
	}
	if ev.Kind != nostr.KindGiftWrap {
		if len(recipients) == 0 {
			// Tags none of the accounts. As before, a stranger's is a web
			// rejection (it can change), anyone else's is for good.
			if !inAnyAccountsWeb(ctx, trustKey) && !engagesOwnerPost(ctx, ev) {
				return nil, rejectNotInWot
			}
		} else if recipients = admittingAccounts(ctx, recipients, trustKey, ev); len(recipients) == 0 {
			return nil, rejectNotInWot
		}
	}
	if len(recipients) == 0 {
		return nil, rejectNoWhitelistedPTag
	}
	return recipients, rejectNone
}

// mayNowReach rechecks a remembered refusal: pubkey is now in the web of one
// of accounts, the accounts its event tagged, and not blocked by it. With
// none named, any account's web is asked.
func mayNowReach(ctx context.Context, pubkey string, accounts []string) bool {
	if len(accounts) == 0 {
		return inAnyAccountsWeb(ctx, pubkey)
	}
	return slices.ContainsFunc(accounts, func(account string) bool { return reachesAccount(ctx, account, pubkey) })
}

// inAnyAccountsWeb reports whether pubkey is in the web of at least one of
// the vault's accounts that has not blocked it. Only for the questions that name no account: a read
// of the chat relay, an event that tags none of them, and the recheck of a
// remembered rejection (which is then judged again per account).
func inAnyAccountsWeb(ctx context.Context, pubkey string) bool {
	for account := range whitelist() {
		if reachesAccount(ctx, account, pubkey) {
			return true
		}
	}
	return false
}
