package main

import (
	"context"
	"net/http"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// meshMaxUploadBytes caps one blob pushed over the mesh. khatru's Blossom
// upload allocates Content-Length bytes up front and holds the whole blob in
// memory, so the cap is checked before the body is touched.
const meshMaxUploadBytes = 256 << 20

type meshPeerKey struct{}

// isMeshRequest reports whether r came in through the mesh port. Mesh traffic
// arrives from 127.0.0.1 like the owner's own app, so loopback alone must
// never earn a free pass.
func isMeshRequest(r *http.Request) bool {
	return r != nil && r.Context().Value(meshPeerKey{}) != nil
}

// isMeshConn reports whether a relay callback runs on a mesh websocket.
func isMeshConn(ctx context.Context) bool {
	conn := khatru.GetConnection(ctx)
	return conn != nil && isMeshRequest(conn.Request)
}

// meshHandler is the whole mesh door. A mesh peer is an unknown remote
// client (NIP-F1); the owner's other phone gets in only with the owner's
// signature:
//   - GET/HEAD /<sha256>[.ext]: read one blob (meshBlobHandler).
//   - PUT/HEAD /upload: Blossom upload, owner-signed kind 24242 or 403
//     (RejectUpload), at most meshMaxUploadBytes.
//   - websocket on /: outbox relay, EVENTs signed by the owner only
//     (meshOwnerEventsOnly), no queries.
//
// Everything else is 404.
func meshHandler(w http.ResponseWriter, r *http.Request) {
	// khatru takes the client IP from X-Forwarded-For, which would let one
	// peer pick a fresh rate bucket per connection.
	r.Header.Del("X-Forwarded-For")
	r.Header.Del("X-Real-Ip")
	r.Header.Del("X-Forwarded-Host")
	r.Header.Del("X-Forwarded-Proto")

	switch {
	case r.URL.Path == "/upload" && (r.Method == http.MethodPut || r.Method == http.MethodHead):
		if r.Method == http.MethodPut {
			if r.ContentLength <= 0 {
				http.Error(w, "Content-Length required", http.StatusLengthRequired)
				return
			}
			if r.ContentLength > meshMaxUploadBytes {
				http.Error(w, "blob too large for the mesh", http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, meshMaxUploadBytes)
		}
		// Keep the request on the Blossom mux: khatru routes websocket,
		// NIP-11 and NIP-86 by header before the path.
		r.Header.Del("Upgrade")
		r.Header.Del("Accept")
		if r.Header.Get("Content-Type") == "application/nostr+json+rpc" {
			r.Header.Del("Content-Type")
		}
		dynamicRelayHandler(w, markMesh(r))
	case r.URL.Path == "/" && r.Method == http.MethodGet && r.Header.Get("Upgrade") == "websocket":
		r.Header.Del("Accept")
		r.Header.Del("Content-Type")
		dynamicRelayHandler(w, markMesh(r))
	default:
		meshBlobHandler(w, r)
	}
}

func markMesh(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), meshPeerKey{}, true))
}

// meshOwnerEventsOnly: over the mesh, the outbox stores only events the
// owner (or a whitelisted account) signed. An AUTHed session does not widen
// it to other people's events the way MustBeWhitelistedToPost does.
func meshOwnerEventsOnly(ctx context.Context, event *nostr.Event) (bool, string) {
	if !isMeshConn(ctx) {
		return false, ""
	}
	if _, ok := config.WhitelistedPubKeys[event.PubKey]; ok {
		return false, ""
	}
	return true, "restricted: the mesh accepts only the owner's own events"
}

// meshNoQueries: a mesh websocket is for sending. Reading the vault over the
// mesh is blob GET only.
func meshNoQueries(ctx context.Context, _ nostr.Filter) (bool, string) {
	if isMeshConn(ctx) {
		return true, "restricted: no queries over the mesh"
	}
	return false, ""
}

// meshAwareConnectionLimiter is bypassLocalhostConnectionLimiter except for
// mesh connections, which always face the limiter.
func meshAwareConnectionLimiter(inner func(r *http.Request) bool) func(r *http.Request) bool {
	local := bypassLocalhostConnectionLimiter(inner)
	return func(r *http.Request) bool {
		if isMeshRequest(r) {
			return inner(r)
		}
		return local(r)
	}
}

