package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/barrydeen/haven/pkg/wot"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// bypassLocalhostConnectionLimiter wraps a RejectConnection policy so that
// connections originating from loopback (the owner's own app talking to its
// embedded relay) are NEVER rejected. The IP-based ConnectionRateLimiter is
// meant to throttle external strangers; applied to localhost it throttles the
// app against itself — a burst of legitimate local connections (DM inbox, feed
// parent/quoted-note fetches, stats) exhausts the small token bucket and the
// relay starts answering 429, which the client retries, producing a reconnect
// storm that pins CPU and janks the UI.
func bypassLocalhostConnectionLimiter(inner func(r *http.Request) bool) func(r *http.Request) bool {
	return func(r *http.Request) bool {
		if ownerConn(r) {
			return false // the browser build's owner streams, by identity
		}
		host := r.RemoteAddr
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if host == "127.0.0.1" || host == "::1" || host == "localhost" ||
			strings.HasPrefix(host, "127.") {
			return false // allow: never rate-limit the owner's own app
		}
		return inner(r)
	}
}

// behindProxy is set (HAVEN_BEHIND_PROXY=1) when every client reaches this
// engine through a front door on loopback: the Linux box's havend, which
// sets X-Forwarded-For to the real client. Without it every LAN or mesh
// client would arrive as 127.0.0.1, get bypassLocalhostConnectionLimiter's
// free pass, and never be rate-limited.
var behindProxy bool

// clientFromProxy returns r with RemoteAddr set to the client the front door
// names in X-Forwarded-For (the last entry: the one the door added), so the
// limiters, the loopback bypass and the logs all see that client. Only a
// loopback peer is trusted to name one. A request from the door with no
// X-Forwarded-For is the box's own (havend asking the vault) and stays
// loopback; one with an address that does not parse is limited as unknown,
// never let through as loopback.
func clientFromProxy(r *http.Request) *http.Request {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return r
	}
	xff := strings.Join(r.Header.Values("X-Forwarded-For"), ",")
	if strings.TrimSpace(xff) == "" {
		return r
	}
	parts := strings.Split(xff, ",")
	client := "0.0.0.0"
	if ip := net.ParseIP(strings.TrimSpace(parts[len(parts)-1])); ip != nil {
		client = ip.String()
	}
	out := r.WithContext(r.Context())
	out.Header = r.Header.Clone()
	out.Header.Del("X-Forwarded-For")
	out.Header.Del("X-Real-Ip")
	out.Header.Del("Forwarded")
	out.RemoteAddr = net.JoinHostPort(client, "0")
	return out
}

// proxyAware runs next with the proxied client in place when behindProxy.
func proxyAware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if behindProxy {
			r = clientFromProxy(r)
		}
		next(w, r)
	}
}

// ownerConn reports whether r arrived on a connection the host marked as the
// owner's own. Only the browser build sets it (wasm_entry.go): its streams
// have no loopback address to bypass on, and a synthetic loopback address
// would hand the bypass to every caller.
var ownerConn = func(*http.Request) bool { return false }

// ownerStream is ownerConn for the connection an event or filter arrived on.
func ownerStream(ctx context.Context) bool {
	ws := khatru.GetConnection(ctx)
	return ws != nil && ws.Request != nil && ownerConn(ws.Request)
}

// whitelistBypassEventRateLimiter wraps EventIPRateLimiter so that events from
// whitelisted pubkeys (the owner and any allowed accounts) are never rate-limited.
// This prevents the relay's own sync and heavy publishing from being blocked by
// the IP-based bucket that was designed to throttle external strangers.
func whitelistBypassEventRateLimiter(tokensPerInterval int, interval time.Duration, maxTokens int) func(ctx context.Context, evt *nostr.Event) (bool, string) {
	inner := policies.EventIPRateLimiter(tokensPerInterval, interval, maxTokens)
	return func(ctx context.Context, evt *nostr.Event) (bool, string) {
		if _, ok := config.WhitelistedPubKeys[evt.PubKey]; ok {
			return false, ""
		}
		// The browser build's owner streams: the page itself caching its
		// follows' notes into /feed, which natively feedsync writes directly.
		if ownerStream(ctx) {
			return false, ""
		}
		return inner(ctx, evt)
	}
}

func MustBeWhitelistedToQuery(ctx context.Context, _ nostr.Filter) (bool, string) {
	authenticatedUser := khatru.GetAuthed(ctx)
	if _, ok := config.WhitelistedPubKeys[authenticatedUser]; !ok {
		slog.Debug("🚫 query rejected: user is not whitelisted", "user", authenticatedUser)
		return true, "restricted: you must be whitelisted to query this relay"
	}
	return false, ""
}

func MustBeInWotToQuery(ctx context.Context, _ nostr.Filter) (bool, string) {
	authenticatedUser := khatru.GetAuthed(ctx)
	if !wot.GetInstance().Has(ctx, authenticatedUser) {
		slog.Debug("🚫 query rejected: user is not in the web of trust", "user", authenticatedUser)
		return true, "restricted: you must be in the web of trust to query this relay"
	}
	return false, ""
}

func MustBeWhitelistedToPost(ctx context.Context, event *nostr.Event) (bool, string) {
	// Event from a whitelisted pubkey can always be posted, even if the user is not authenticated
	if _, ok := config.WhitelistedPubKeys[event.PubKey]; ok {
		return false, ""
	}
	authenticatedUser := khatru.GetAuthed(ctx)
	if authenticatedUser == "" {
		return true, "auth-required: you must be authenticated to post to this relay"
	}
	if _, ok := config.WhitelistedPubKeys[authenticatedUser]; !ok {
		slog.Debug("🚫 event rejected: user is not whitelisted", "event", event.ID, "pubkey", authenticatedUser)
		return true, "restricted: you must be whitelisted to post to this relay"
	}
	return false, ""
}

func MustBeInWotToPost(ctx context.Context, event *nostr.Event) (bool, string) {
	// Event from a pubkey in the WoT can always be posted, even if the user is not authenticated
	if wot.GetInstance().Has(ctx, event.PubKey) {
		return false, ""
	}
	// Anyone may reply to or quote the owner's own posts (see classifyInboxEvent).
	if engagesOwnerPost(ctx, event) {
		return false, ""
	}
	authenticatedUser := khatru.GetAuthed(ctx)
	if authenticatedUser == "" {
		return true, "auth-required: you must be authenticated to post to this relay"
	}
	if !wot.GetInstance().Has(ctx, authenticatedUser) {
		slog.Debug("🚫 event rejected: user is not in web of trust", "event", event.ID, "pubkey", authenticatedUser)
		return true, "you must be in the web of trust to post to this relay"
	}
	return false, ""
}

func MustNotBeBlacklistedToPost(ctx context.Context, event *nostr.Event) (bool, string) {
	// Events from a blacklisted pubkey ARE always rejected
	if isBlacklisted(event.PubKey) {
		slog.Debug("🚫 event rejected: event author is blacklisted", "event", event.ID, "pubkey", event.PubKey)
		return true, "you are blacklisted from this relay"
	}
	// The owner's delete requests carry the owner's signature, so there is nothing
	// left for an AUTH round trip to prove
	if isOwnerDeleteRequest(event) {
		return false, ""
	}
	// Still need auth due to GiftWrap and other events with random pubkeys
	authenticatedUser := khatru.GetAuthed(ctx)
	if authenticatedUser == "" {
		return true, "auth-required: you must be authenticated to post to this relay"
	}
	if isBlacklisted(authenticatedUser) {
		slog.Debug("🚫 event rejected: authenticated user is blacklisted", "event", event.ID, "pubkey", authenticatedUser)
		return true, "you are blacklisted from this relay"
	}
	return false, ""
}

// isOwnerDeleteRequest reports whether the event is a NIP-09 delete request from
// the relay owner. Signatures are verified before any policy runs, so the pubkey
// on the event is proof enough that the owner sent it.
func isOwnerDeleteRequest(event *nostr.Event) bool {
	return event.Kind == nostr.KindDeletion && event.PubKey == config.OwnerPubKey
}

// OwnerCanDeleteAnyEvent replaces khatru's default NIP-09 outcome, which only
// lets authors delete their own events, so that the owner can delete anything
// stored on their relay. Everybody else is still limited to their own events.
func OwnerCanDeleteAnyEvent(_ context.Context, target *nostr.Event, deletion *nostr.Event) (bool, string) {
	if target.PubKey == deletion.PubKey {
		return true, ""
	}

	if deletion.PubKey == config.OwnerPubKey {
		slog.Info("🗑️ owner deleted an event", "event", target.ID, "kind", target.Kind, "author", target.PubKey)
		return true, ""
	}

	slog.Debug("🚫 deletion rejected: user is not the author of the event", "event", target.ID, "pubkey", deletion.PubKey)
	return false, "you are not the author of this event"
}

// MustNotBeDeleted rejects events that have already been deleted from db, so a
// re-publish can't resurrect what the owner or the author deleted.
func MustNotBeDeleted(db DBBackend) func(context.Context, *nostr.Event) (bool, string) {
	return func(ctx context.Context, event *nostr.Event) (bool, string) {
		if isDeleted(ctx, db, event) {
			slog.Debug("🚫 event rejected: event has been deleted", "event", event.ID, "pubkey", event.PubKey)
			return true, "this event has been deleted"
		}
		return false, ""
	}
}

var allowedChatKinds = map[int]struct{}{
	// Regular kinds
	nostr.KindSimpleGroupChatMessage:   {},
	nostr.KindSimpleGroupThreadedReply: {},
	nostr.KindSimpleGroupThread:        {},
	nostr.KindSimpleGroupReply:         {},
	nostr.KindChannelMessage:           {},
	nostr.KindChannelHideMessage:       {},

	nostr.KindGiftWrap: {},

	nostr.KindSimpleGroupPutUser:      {},
	nostr.KindSimpleGroupRemoveUser:   {},
	nostr.KindSimpleGroupEditMetadata: {},
	nostr.KindSimpleGroupDeleteEvent:  {},
	nostr.KindSimpleGroupCreateGroup:  {},
	nostr.KindSimpleGroupDeleteGroup:  {},
	nostr.KindSimpleGroupCreateInvite: {},
	nostr.KindSimpleGroupJoinRequest:  {},
	nostr.KindSimpleGroupLeaveRequest: {},

	// Addressable kinds
	nostr.KindSimpleGroupMetadata: {},
	nostr.KindSimpleGroupAdmins:   {},
	nostr.KindSimpleGroupMembers:  {},
	nostr.KindSimpleGroupRoles:    {},
}

func EventMustBeChatRelated(_ context.Context, event *nostr.Event) (bool, string) {
	if _, ok := allowedChatKinds[event.Kind]; ok {
		return false, ""
	}

	// the owner's delete requests are stored so the deletion survives a re-publish
	if isOwnerDeleteRequest(event) {
		return false, ""
	}

	return true, "only chat related events are allowed"
}

func OnlyGiftWrappedDMs(_ context.Context, event *nostr.Event) (bool, string) {
	if event.Kind == nostr.KindEncryptedDirectMessage {
		return true, "only gift wrapped DMs are supported"
	}
	return false, ""
}

func MustTagWhitelistedPubKey(_ context.Context, event *nostr.Event) (bool, string) {
	// the owner's delete requests are stored so the deletion survives a re-publish
	if isOwnerDeleteRequest(event) {
		return false, ""
	}

	// User must tag at least one whitelisted pubkey in this relay
	tags := event.Tags.FindAll("p")
	for tag := range tags {
		if len(tag) < 2 {
			continue
		}
		if _, ok := config.WhitelistedPubKeys[tag[1]]; ok {
			return false, ""
		}
	}

	slog.Debug("🚫 event rejected: event does not tag any whitelisted pubkey", "eventID", event.ID)

	return true, "you can only post notes if you've tagged a whitelisted pubkey in this relay"
}
