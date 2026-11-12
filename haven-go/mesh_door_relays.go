package main

import (
	"context"
	"net/http"
	"strings"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Sync rework M2 (RESEARCH/NV_SYNC_REWORK_BUILD_PLAN_2026_11_12.md §1): the
// mesh door also serves /inbox, /chat and /private, with the https rules
// (init.go) and the mesh caps (wireMeshReadCaps). Nothing that comes in
// through the door is blasted: only the outbox blasts, and not mesh writes.

// meshDoorRelayPaths are the websocket paths the door opens besides "/".
var meshDoorRelayPaths = map[string]bool{"/inbox": true, "/chat": true, "/private": true}

// meshAuthURL is the URL a NIP-42 AUTH over the mesh must name in its
// `relay` tag: this vault's mesh address, ws://<mesh npub>.fips<path> (what
// a FIPS client dials). Pinned, never taken from the request: over the mesh
// the Host header is the client's to choose, and a hostile relay that
// forwards a challenge could otherwise log in as the owner (Tron 4,
// RESEARCH/NV_MESH_ATTACK_B_2026_11_12.md). With no HAVEN_MESH_NPUB (the
// host app or the box hands it over), no AUTH over the mesh can succeed.
func meshAuthURL(path string) string {
	npub := strings.TrimSpace(hostGetenv("HAVEN_MESH_NPUB"))
	if prefix, _, err := nip19.Decode(npub); err != nil || prefix != "npub" {
		return "http://mesh-npub-unknown.invalid" + path
	}
	return "http://" + npub + ".fips" + path
}

// pinMeshAuthURL makes rl check a mesh AUTH against meshAuthURL(path); any
// other connection keeps what it had (ServiceURLFor or ServiceURL). Call it
// after serviceURLFromHost.
func pinMeshAuthURL(rl *khatru.Relay, path string) {
	prev, fixed := rl.ServiceURLFor, rl.ServiceURL
	rl.ServiceURLFor = func(r *http.Request) string {
		if isMeshRequest(r) {
			return meshAuthURL(path)
		}
		if prev != nil {
			return prev(r)
		}
		return fixed
	}
}

// meshInboxGiftWrapOnly: over the mesh /inbox takes gift wraps (kind 1059)
// and nothing else. Over https it also takes WoT replies and mentions that
// tag the owner; the mesh door is for delivering DMs.
func meshInboxGiftWrapOnly(ctx context.Context, ev *nostr.Event) (bool, string) {
	if isMeshConn(ctx) && ev.Kind != nostr.KindGiftWrap {
		return true, "restricted: over the mesh this relay takes only gift-wrapped messages"
	}
	return false, ""
}

// meshInboxReadsNeedAuth: over the mesh /inbox is read only by the vault's
// own accounts (NIP-42 AUTH, pinned). Over https it reads open.
func meshInboxReadsNeedAuth(ctx context.Context, _ nostr.Filter) (bool, string) {
	if !isMeshConn(ctx) {
		return false, ""
	}
	authed := khatru.GetAuthed(ctx)
	if authed == "" {
		return true, "auth-required: reading this relay over the mesh needs you to authenticate"
	}
	if _, ok := whitelist()[authed]; !ok {
		return true, "restricted: over the mesh only this vault's accounts read this relay"
	}
	return false, ""
}
