package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"os"
	"strings"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Sync rework M2 (RESEARCH/NV_SYNC_REWORK_BUILD_PLAN_2026_11_12.md §1), as
// Logen picked it (B, 2026-11-12): over the mesh the door takes incoming DMs
// only. /inbox takes gift-wrap writes (the https rules, init.go, plus the
// mesh caps, wireMeshReadCaps); every mesh read of /inbox is refused, and
// /chat and /private are not served over the mesh at all. Nothing on the
// mesh needs the account key (Logen's 2026-11-05 rule). Nothing that comes in
// through the door is blasted: only the outbox blasts, and not mesh writes.

// meshDoorRelayPaths are the websocket paths the door opens besides "/".
// /files: the owner's media file notes, for the owner's own devices
// (files_relay.go).
var meshDoorRelayPaths = map[string]bool{"/inbox": true, filesPath: true}

// meshAuthURL is the URL a NIP-42 AUTH over the mesh must name in its
// `relay` tag: this vault's mesh address, ws://<mesh npub>.fips<path> (what
// a FIPS client dials). Pinned, never taken from the request: over the mesh
// the Host header is the client's to choose, and a hostile relay that
// forwards a challenge could otherwise log in as the owner (Tron 4,
// RESEARCH/NV_MESH_ATTACK_B_2026_11_12.md). With no mesh npub known
// (meshOwnNpub), no AUTH over the mesh can succeed.
func meshAuthURL(path string) string {
	npub := meshOwnNpub()
	if npub == "" {
		// Refused outright: a host made at random when the process starts,
		// so no AUTH can name it (an empty URL would match an empty tag).
		return "http://" + meshAuthOff + ".invalid" + path
	}
	return "http://" + npub + ".fips" + path
}

// meshAuthOff is the unguessable host meshAuthURL names while the vault does
// not know its mesh npub.
var meshAuthOff = func() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return "mesh-auth-off-" + hex.EncodeToString(b)
}()

// meshOwnNpub is this vault's mesh npub: HAVEN_MESH_NPUB (the apps hand it
// over when they open the door), or else the file HAVEN_MESH_NPUB_FILE names
// (the box: nv-mesh writes it on its first start, maybe after the engine
// started, so it is read when an AUTH comes, not once). "" if neither holds a
// valid npub.
func meshOwnNpub() string {
	npub := strings.TrimSpace(hostGetenv("HAVEN_MESH_NPUB"))
	if npub == "" {
		if f := strings.TrimSpace(hostGetenv("HAVEN_MESH_NPUB_FILE")); f != "" {
			if b, err := os.ReadFile(f); err == nil && len(b) <= 1024 {
				npub = strings.TrimSpace(string(b))
			}
		}
	}
	if prefix, _, err := nip19.Decode(npub); err != nil || prefix != "npub" || npub != strings.ToLower(npub) {
		return ""
	}
	return npub
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

// meshInboxNoReads: over the mesh /inbox is for delivering DMs, never for
// reading them, whoever is AUTHed (Logen's pick B). Over https it reads
// open, as before.
func meshInboxNoReads(ctx context.Context, _ nostr.Filter) (bool, string) {
	if isMeshConn(ctx) {
		return true, "restricted: over the mesh this relay only takes incoming messages"
	}
	return false, ""
}
