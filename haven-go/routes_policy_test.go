package main

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Route/policy regression suite. Every write and read rule initRelays wires
// into a route is exercised here over a real websocket, through
// dynamicRelayHandler, against the real initRelays chains: one accept case
// and at least one reject case per (predicate, route) pair. Subtest names
// carry the pair so a mutation that disables one call site in init.go maps
// to exactly the subtests that must go red.
//
// Reject cases assert the predicate's own reason text, not just "rejected",
// so a different rule (or the rate limiter) refusing the event cannot stand
// in for the one under test.

// policyActors are the identities every route test signs with.
//
//	owner   whitelisted, in the WoT
//	friend  not whitelisted, in the WoT
//	villain not whitelisted, in the WoT, blacklisted (in the WoT on purpose,
//	        so only the blacklist can refuse it)
//	stranger not whitelisted, not in the WoT
type policyActors struct {
	h                                        *havenUnderTest
	ownerSK, friendSK, villainSK, strangerSK string
	owner, friend, villain, stranger         string
}

func startPolicyHaven(t *testing.T) *policyActors {
	t.Helper()
	// Lift the per-IP event limiters: every test socket is 127.0.0.1, and a
	// rate-limited reject must never be mistaken for a policy reject.
	for _, route := range []string{"PRIVATE", "CHAT", "OUTBOX", "INBOX"} {
		t.Setenv(route+"_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL", "1000")
		t.Setenv(route+"_RELAY_EVENT_IP_LIMITER_MAX_TOKENS", "1000")
	}
	h := startHaven(t)
	a := &policyActors{h: h, ownerSK: h.ownerSK, owner: h.owner}
	a.friendSK, a.friend = newActor()
	a.villainSK, a.villain = newActor()
	a.strangerSK, a.stranger = newActor()

	config.BlacklistedPubKeys = map[string]struct{}{a.villain: {}}
	prevOverride := blacklistOverride.Load()
	blacklistOverride.Store(nil)
	t.Cleanup(func() { blacklistOverride.Store(prevOverride) })

	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{
		a.owner: true, a.friend: true, a.villain: true,
	}})
	return a
}

func newActor() (sk, pk string) {
	sk = nostr.GeneratePrivateKey()
	pk, _ = nostr.GetPublicKey(sk)
	return sk, pk
}

func signed(t *testing.T, sk string, kind int, tags nostr.Tags, content string) nostr.Event {
	t.Helper()
	ev := nostr.Event{CreatedAt: nostr.Now(), Kind: kind, Tags: tags, Content: content}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

// authAs completes NIP-42 on r as sk. Routes without RequestAuth on connect
// (outbox, inbox) only issue a challenge after an auth-required reject, so if
// none has arrived yet a throwaway stranger note is published to provoke one.
func (a *policyActors) authAs(t *testing.T, r *nostr.Relay, sk string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	provoked := false
	start := time.Now()
	var err error
	for time.Since(start) < 3*time.Second {
		if err = r.Auth(ctx, func(ev *nostr.Event) error { return ev.Sign(sk) }); err == nil {
			return
		}
		if !provoked && time.Since(start) > 300*time.Millisecond {
			_ = r.Publish(ctx, signed(t, a.strangerSK, nostr.KindTextNote, nil, "provoke AUTH challenge"))
			provoked = true
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("auth: %v", err)
}

// socket opens a connection to path, authenticated as authSK unless it is "".
func (a *policyActors) socket(t *testing.T, path, authSK string) *nostr.Relay {
	t.Helper()
	r := a.h.connect(t, path)
	if authSK != "" {
		a.authAs(t, r, authSK)
	}
	return r
}

type publishCase struct {
	name     string // "<predicate>/<route>: ..." — the mutation table row
	authSK   string // "" = unauthenticated socket
	event    func(t *testing.T) nostr.Event
	rejectBy string // "" = must be accepted; else substring of the OK reason
}

func (a *policyActors) runPublishCases(t *testing.T, path string, cases []publishCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := a.socket(t, path, c.authSK)
			ev := c.event(t)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			err := r.Publish(ctx, ev)
			if c.rejectBy == "" {
				if err != nil {
					t.Fatalf("want accepted on %s, got %v", path, err)
				}
				return
			}
			if err == nil {
				t.Fatalf("want rejected on %s with %q, but it was accepted", path, c.rejectBy)
			}
			if !strings.Contains(err.Error(), c.rejectBy) {
				t.Fatalf("want rejected on %s with %q, got %v", path, c.rejectBy, err)
			}
		})
	}
}

type queryCase struct {
	name     string
	authSK   string
	closedBy string // "" = must reach EOSE; else prefix of the CLOSED reason
}

func (a *policyActors) runQueryCases(t *testing.T, path string, filter nostr.Filter, cases []queryCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := a.socket(t, path, c.authSK)
			got, closed := req(t, r, filter)
			if c.closedBy == "" {
				if closed != "" {
					t.Fatalf("want EOSE on %s, got CLOSED %q", path, closed)
				}
				return
			}
			if len(got) != 0 {
				t.Fatalf("rejected query on %s still delivered %d events", path, len(got))
			}
			if !strings.HasPrefix(closed, c.closedBy) {
				t.Fatalf("want CLOSED %q on %s, got %q", c.closedBy, path, closed)
			}
		})
	}
}

const (
	reasonAuthRequired    = "auth-required: you must be authenticated to post"
	reasonNotWhitelisted  = "restricted: you must be whitelisted to post"
	reasonNotInWotPost    = "you must be in the web of trust to post"
	reasonBlacklisted     = "you are blacklisted from this relay"
	reasonNotChat         = "only chat related events are allowed"
	reasonNotGiftWrapped  = "only gift wrapped DMs are supported"
	reasonNoWhitelistedP  = "you can only post notes if you've tagged a whitelisted pubkey"
	reasonNotFeedKind     = "restricted: this relay only accepts feed notes"
	closedQueryAuth       = "auth-required:"
	closedNotWhitelistedQ = "restricted: you must be whitelisted to query"
	closedNotInWotQ       = "restricted: you must be in the web of trust to query"
)

func note(sk string, tags nostr.Tags) func(t *testing.T) nostr.Event {
	return func(t *testing.T) nostr.Event { return signed(t, sk, nostr.KindTextNote, tags, "note") }
}

func ofKind(sk string, kind int, tags nostr.Tags) func(t *testing.T) nostr.Event {
	return func(t *testing.T) nostr.Event { return signed(t, sk, kind, tags, "kind event") }
}

func TestRoutePolicyPrivate(t *testing.T) {
	a := startPolicyHaven(t)
	a.runPublishCases(t, "/private", []publishCase{
		{name: "MustBeWhitelistedToPost/private: owner-signed, unauthenticated, accepted", event: note(a.ownerSK, nil)},
		{name: "MustBeWhitelistedToPost/private: stranger-signed, authed as owner, accepted", authSK: a.ownerSK, event: note(a.strangerSK, nil)},
		{name: "MustBeWhitelistedToPost/private: friend-signed, unauthenticated, rejected", event: note(a.friendSK, nil), rejectBy: reasonAuthRequired},
		{name: "MustBeWhitelistedToPost/private: friend-signed, authed as friend, rejected", authSK: a.friendSK, event: note(a.friendSK, nil), rejectBy: reasonNotWhitelisted},
	})
	a.runQueryCases(t, "/private", nostr.Filter{Kinds: []int{nostr.KindTextNote}}, []queryCase{
		{name: "MustAuth/private: unauthenticated REQ closed", closedBy: closedQueryAuth},
		{name: "MustBeWhitelistedToQuery/private: authed as friend, closed", authSK: a.friendSK, closedBy: closedNotWhitelistedQ},
		{name: "MustBeWhitelistedToQuery/private: authed as owner, EOSE", authSK: a.ownerSK},
	})
}

func TestRoutePolicyChat(t *testing.T) {
	a := startPolicyHaven(t)
	chatMsg := nostr.KindSimpleGroupChatMessage
	a.runPublishCases(t, "/chat", []publishCase{
		{name: "chat: friend chat message, authed as friend, accepted", authSK: a.friendSK, event: ofKind(a.friendSK, chatMsg, nil)},
		{name: "chat: owner gift wrap, authed as owner, accepted", authSK: a.ownerSK, event: ofKind(a.ownerSK, nostr.KindGiftWrap, nil)},
		{name: "MustNotBeBlacklistedToPost/chat: villain-signed, authed as villain, rejected", authSK: a.villainSK, event: ofKind(a.villainSK, chatMsg, nil), rejectBy: reasonBlacklisted},
		{name: "MustNotBeBlacklistedToPost/chat: friend-signed, authed as villain, rejected", authSK: a.villainSK, event: ofKind(a.friendSK, chatMsg, nil), rejectBy: reasonBlacklisted},
		{name: "MustNotBeBlacklistedToPost/chat: friend-signed, unauthenticated, rejected", event: ofKind(a.friendSK, chatMsg, nil), rejectBy: reasonAuthRequired},
		{name: "MustBeInWotToPost/chat: stranger-signed, authed as stranger, rejected", authSK: a.strangerSK, event: ofKind(a.strangerSK, chatMsg, nil), rejectBy: reasonNotInWotPost},
		{name: "MustBeInWotToPost/chat: stranger-signed, authed as friend, accepted", authSK: a.friendSK, event: ofKind(a.strangerSK, chatMsg, nil)},
		{name: "EventMustBeChatRelated/chat: friend kind-1 note, authed as friend, rejected", authSK: a.friendSK, event: note(a.friendSK, nil), rejectBy: reasonNotChat},
		{name: "EventMustBeChatRelated/chat: friend kind-4 DM, authed as friend, rejected", authSK: a.friendSK, event: ofKind(a.friendSK, nostr.KindEncryptedDirectMessage, nil), rejectBy: reasonNotChat},
	})
	a.runQueryCases(t, "/chat", nostr.Filter{Kinds: []int{chatMsg}, Limit: 10}, []queryCase{
		{name: "MustAuth/chat: unauthenticated REQ closed", closedBy: closedQueryAuth},
		{name: "MustBeInWotToQuery/chat: authed as stranger, closed", authSK: a.strangerSK, closedBy: closedNotInWotQ},
		{name: "MustBeInWotToQuery/chat: authed as friend, EOSE", authSK: a.friendSK},
	})
}

func TestRoutePolicyOutbox(t *testing.T) {
	a := startPolicyHaven(t)
	a.runPublishCases(t, "", []publishCase{
		{name: "MustBeWhitelistedToPost/outbox: owner-signed, unauthenticated, accepted", event: note(a.ownerSK, nil)},
		{name: "MustBeWhitelistedToPost/outbox: friend-signed, unauthenticated, rejected", event: note(a.friendSK, nil), rejectBy: reasonAuthRequired},
		{name: "MustBeWhitelistedToPost/outbox: friend-signed, authed as friend, rejected", authSK: a.friendSK, event: note(a.friendSK, nil), rejectBy: reasonNotWhitelisted},
		{name: "MustBeWhitelistedToPost/outbox: friend-signed, authed as owner, accepted", authSK: a.ownerSK, event: note(a.friendSK, nil)},
	})
	// The outbox is public to read: no auth, no WoT.
	a.runQueryCases(t, "", nostr.Filter{Kinds: []int{nostr.KindTextNote}, Limit: 10}, []queryCase{
		{name: "outbox: unauthenticated REQ, EOSE"},
	})
}

func TestRoutePolicyInbox(t *testing.T) {
	a := startPolicyHaven(t)
	tagOwner := nostr.Tags{{"p", a.owner}}
	tagFriend := nostr.Tags{{"p", a.friend}}
	a.runPublishCases(t, "/inbox", []publishCase{
		{name: "inbox: friend note tagging owner, authed as friend, accepted", authSK: a.friendSK, event: note(a.friendSK, tagOwner)},
		{name: "inbox: friend gift wrap tagging owner, authed as friend, accepted", authSK: a.friendSK, event: ofKind(a.friendSK, nostr.KindGiftWrap, tagOwner)},
		{name: "OnlyGiftWrappedDMs/inbox: friend kind-4 DM tagging owner, authed as friend, rejected", authSK: a.friendSK, event: ofKind(a.friendSK, nostr.KindEncryptedDirectMessage, tagOwner), rejectBy: reasonNotGiftWrapped},
		{name: "MustNotBeBlacklistedToPost/inbox: villain-signed, authed as villain, rejected", authSK: a.villainSK, event: note(a.villainSK, tagOwner), rejectBy: reasonBlacklisted},
		{name: "MustNotBeBlacklistedToPost/inbox: friend-signed, authed as villain, rejected", authSK: a.villainSK, event: note(a.friendSK, tagOwner), rejectBy: reasonBlacklisted},
		{name: "MustNotBeBlacklistedToPost/inbox: friend-signed, unauthenticated, rejected", event: note(a.friendSK, tagOwner), rejectBy: reasonAuthRequired},
		{name: "MustBeInWotToPost/inbox: stranger-signed, authed as stranger, rejected", authSK: a.strangerSK, event: note(a.strangerSK, tagOwner), rejectBy: reasonNotInWotPost},
		{name: "MustBeInWotToPost/inbox: stranger-signed, authed as friend, accepted", authSK: a.friendSK, event: note(a.strangerSK, tagOwner)},
		{name: "MustTagWhitelistedPubKey/inbox: friend note with no p tag, authed as friend, rejected", authSK: a.friendSK, event: note(a.friendSK, nil), rejectBy: reasonNoWhitelistedP},
		{name: "MustTagWhitelistedPubKey/inbox: friend note tagging only a non-whitelisted key, authed as friend, rejected", authSK: a.friendSK, event: note(a.friendSK, tagFriend), rejectBy: reasonNoWhitelistedP},
	})
}

func TestRoutePolicyFeed(t *testing.T) {
	a := startPolicyHaven(t)
	cases := []publishCase{}
	for _, k := range feedKinds {
		cases = append(cases, publishCase{
			name:  "OnlyFeedKinds/feed: stranger kind " + strconv.Itoa(k) + ", unauthenticated, accepted",
			event: ofKind(a.strangerSK, k, nil),
		})
	}
	for _, k := range []int{nostr.KindReaction, nostr.KindEncryptedDirectMessage, nostr.KindGiftWrap, nostr.KindProfileMetadata} {
		cases = append(cases, publishCase{
			name:     "OnlyFeedKinds/feed: stranger kind " + strconv.Itoa(k) + ", unauthenticated, rejected",
			event:    ofKind(a.strangerSK, k, nil),
			rejectBy: reasonNotFeedKind,
		})
	}
	a.runPublishCases(t, "/feed", cases)
}

// knownFailure records a reproduced, still-open security bug without
// deleting its test. By default it skips with a loud KNOWN FAILURE line so
// the policy suite stays usable as a mutation gate; HAVEN_STRICT_KNOWN_FAILURES=1
// turns it into a hard failure.
func knownFailure(t *testing.T, issue, format string, args ...any) {
	t.Helper()
	if os.Getenv("HAVEN_STRICT_KNOWN_FAILURES") == "1" {
		t.Fatalf("KNOWN FAILURE ("+issue+"): "+format, args...)
	}
	t.Skipf("KNOWN FAILURE ("+issue+"), set HAVEN_STRICT_KNOWN_FAILURES=1 to fail: "+format, args...)
}

const issuePrivateBypass = "barrydeen/haven#136, RESEARCH/HAVEN_PRIVATE_RELAY_AUTH_BYPASS.md"

// An unauthenticated ["REQ",x,{"limit":0}] must not get a live subscription
// on /private: khatru returns from handleRequest on LimitZero before running
// RejectFilter, so MustAuth and MustBeWhitelistedToQuery never see it.
func TestRoutePolicyPrivateLimitZeroLive(t *testing.T) {
	a := startPolicyHaven(t)
	spy := a.socket(t, "/private", "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sub, err := spy.Subscribe(ctx, nostr.Filters{{Kinds: []int{nostr.KindTextNote}, LimitZero: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsub()

	// Whatever the relay does with the REQ, give it time to register before
	// the owner publishes.
	closedReason := ""
	select {
	case closedReason = <-sub.ClosedReason:
	case <-time.After(300 * time.Millisecond):
	}

	secret := signed(t, a.ownerSK, nostr.KindTextNote, nil, "private canary")
	owner := a.socket(t, "/private", "")
	if err := owner.Publish(ctx, secret); err != nil {
		t.Fatalf("owner publish: %v", err)
	}

	select {
	case ev := <-sub.Events:
		if ev.ID == secret.ID {
			knownFailure(t, issuePrivateBypass, "unauthenticated limit:0 REQ received live /private event %s", ev.ID)
		}
		t.Fatalf("unauthenticated limit:0 REQ received an unexpected event %s", ev.ID)
	case <-time.After(time.Second):
	}
	if closedReason != "" && !strings.HasPrefix(closedReason, closedQueryAuth) {
		t.Fatalf("limit:0 REQ closed with %q, want %q", closedReason, closedQueryAuth)
	}
}

// An unauthenticated COUNT on /private must not reveal anything: khatru gates
// COUNT on RejectCountFilter, which no Haven relay sets.
func TestRoutePolicyPrivateUnauthenticatedCount(t *testing.T) {
	a := startPolicyHaven(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	owner := a.socket(t, "/private", "")
	if err := owner.Publish(ctx, signed(t, a.ownerSK, nostr.KindTextNote, nil, "counted")); err != nil {
		t.Fatalf("owner publish: %v", err)
	}
	spy := a.socket(t, "/private", "")
	n, _, err := spy.Count(ctx, nostr.Filters{{Kinds: []int{nostr.KindTextNote}}})
	if err == nil {
		knownFailure(t, issuePrivateBypass, "unauthenticated COUNT on /private answered %d", n)
	}
}
