package main

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"strings"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// The relay port's blob rules (Tron, RESEARCH/NV_MESH_ATTACK_REVIEW_2026_11_12.md
// item 1). The mesh door already serves only publicly named blobs
// (mesh_safety.go), but the relay port itself handed /list/<owner hex> and
// every blob to whoever reached it: the LAN (Mac and Android bind 0.0.0.0),
// a relay domain or tunnel, a web page open on the same machine (any-origin
// CORS), and the iPhone's own-device port. The owner's hex is in NIP-11, so
// that was every hash, then every Drive file and private attachment.
//
// Now, on the relay port (Logen's pick B, 2026-11-12):
//   - GET /list/<pubkey> needs the owner's or a paired device's signed
//     "list" (kind 24242), unless the request is the owner's own app.
//   - HEAD /<sha256> of a blob no public note names (meshBlobs, the door's
//     index) needs the owner's or a paired device's signed "get", unless the
//     request is the owner's own app, so a private file's size and type do
//     not leak. A refusal is 404, as for a blob that is not here.
//   - GET /<sha256> by exact hash stays open to everyone. DM photos, share
//     links and the Android picker load vault links unsigned, and with /list
//     closed a hash cannot be listed or guessed. Gating GET waits on the apps
//     signing their reads and DM uploads leaving the vault.
//
// The owner's own app reads its vault over loopback with no signature (image
// loaders, video players, the Stats and Media screens; a keyless vault has
// nothing to sign with), so it is recognised by how it arrives instead
// (relayOwnApp).

// relayOwnAppKey marks a relay-port request relayOwnApp accepted.
type relayOwnAppKey struct{}

// relayOwnApp: r is the owner's own app talking to its own vault: the
// browser build's owner stream, or a request from this machine that
//   - did not come through the mesh door or the iPhone's own-device port
//     (both arrive on loopback, and any app on the phone can dial the latter),
//   - names no tunnel or proxy hop off this machine (copyThroughTunnel,
//     copyFromLoopback: the Mac tunnel and the box's havend arrive on
//     loopback too; viaProxy),
//   - asks for a loopback Host (loopbackHost: DNS rebinding), and
//   - is not from a web page: browsers send Origin on fetches and Sec-Fetch-*
//     on every request, an <img> included; the apps' native HTTP clients
//     send neither. A page open on the same Mac or Android phone could
//     otherwise read the vault through 127.0.0.1.
//
// Another native app on the same device is not told apart; that needs a
// secret the apps pass, which is app work, not haven-go's.
func relayOwnApp(r *http.Request) bool {
	if ownerConn(r) {
		return true
	}
	if isMeshRequest(r) || r.Context().Value(meshOwnPortKey{}) != nil {
		return false
	}
	return relayFromThisMachine(r) && loopbackHost(r.Host) && !viaProxy(r) && !fromWebPage(r)
}

// loopbackHost: the Host the apps dial (127.0.0.1, ::1, localhost). A web
// page on a rebound domain (DNS rebinding to 127.0.0.1) is same-origin, so it
// sends no Origin and no Sec-Fetch-*; only its Host gives it away. A proxy
// that passes the public Host is refused the same way.
func loopbackHost(host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip, err := netip.ParseAddr(host)
	return err == nil && ip.Unmap().IsLoopback()
}

// viaProxy: r names a proxy hop the apps never send.
func viaProxy(r *http.Request) bool {
	for _, h := range []string{"Via", "X-Forwarded-Host", "X-Forwarded-Proto"} {
		if r.Header.Get(h) != "" {
			return true
		}
	}
	return false
}

// relayFromThisMachine: r came from this machine with no tunnel or proxy hop
// named. Set natively (relay_blob_gate_native.go); the browser build has no
// listener, only the owner stream above.
var relayFromThisMachine = func(*http.Request) bool { return false }

// fromWebPage: r carries a browser's request markers.
func fromWebPage(r *http.Request) bool {
	if r.Header.Get("Origin") != "" {
		return true
	}
	for name := range r.Header {
		if strings.HasPrefix(http.CanonicalHeaderKey(name), "Sec-Fetch-") {
			return true
		}
	}
	return false
}

func isRelayOwnApp(ctx context.Context) bool {
	return ctx.Value(relayOwnAppKey{}) != nil
}

// relayBlobGate runs in dynamicRelayHandler before khatru. It marks the own
// app's requests for the Blossom hooks, and answers HEAD of a blob itself:
// khatru answers HEAD from its index with no hook (blossom handleHasBlob),
// which would tell anyone a private blob's size and type. ok false: the
// response is written.
func relayBlobGate(w http.ResponseWriter, r *http.Request) (*http.Request, bool) {
	if isMeshRequest(r) {
		return r, true // the door's own rules (meshBlobHandler, mesh_safety.go)
	}
	if relayOwnApp(r) {
		return r.WithContext(context.WithValue(r.Context(), relayOwnAppKey{}, true)), true
	}
	if r.Method == http.MethodHead {
		if sha, ok := khatruBlobPath(r.URL.Path); ok {
			// meshHeadAllowed: the owner's or a paired device's signed "get"
			// for this blob, or a public note names it.
			if !meshHeadAllowed(r, sha) {
				w.Header().Add("X-Reason", "file not found")
				w.WriteHeader(http.StatusNotFound)
				return r, false
			}
		}
	}
	return r, true
}

// khatruBlobPath: the path khatru's Blossom router sends to handleHasBlob /
// handleGetBlob (khatru/blossom/server.go): one segment, 64 characters, then
// nothing or any suffix starting with a dot ("/<sha>.", "/<sha>.tar.gz").
// blossomBlobPathRe is narrower, so it cannot gate what khatru answers.
func khatruBlobPath(path string) (string, bool) {
	if len(path) < 65 || strings.Contains(path[1:], "/") {
		return "", false
	}
	if len(path) != 65 && path[65] != '.' {
		return "", false
	}
	return strings.ToLower(path[1:65]), true
}

// relayBlobRejectList is the relay port's RejectList: the full blob list
// only to the own app or the owner's or a paired device's signed "list". The mesh door never
// reaches /list (meshBlobHandler serves blob paths only).
func relayBlobRejectList(ctx context.Context, auth *nostr.Event, _ string) (bool, string, int) {
	if isRelayOwnApp(ctx) || ownerOrDeviceAuth(ctx, auth) {
		return false, "", 0
	}
	return true, "listing needs the vault owner's signed authorization", http.StatusUnauthorized
}

// ownerOrDeviceAuth: auth is signed by a whitelisted account, or is the
// paired-device token this request was admitted on (withMeshDeviceAuth).
func ownerOrDeviceAuth(ctx context.Context, auth *nostr.Event) bool {
	if auth == nil {
		return false
	}
	if _, ok := whitelist()[auth.PubKey]; ok {
		return true
	}
	return isMeshDeviceAuth(ctx, auth)
}

// guardRelayBlobs wires the relay port's rules into a Blossom server.
func guardRelayBlobs(bs *blossom.BlossomServer) {
	bs.RejectList = append(bs.RejectList, relayBlobRejectList)
}
