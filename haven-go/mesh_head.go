package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// meshHeadAllowed applies the mesh's GET rules (meshBlobRejectGet) to
// HEAD /<sha256>. khatru answers HEAD from its blob index alone, with no
// auth and no RejectGet (blossom handleHasBlob), so without this any mesh
// peer learned whether the vault holds a blob, with its size and type,
// even one no posted note names (Tron, #1048).
func meshHeadAllowed(r *http.Request, sha256 string) bool {
	return meshOwnerGetAuthorized(r, sha256) || meshBlobs.has(r.Context(), sha256)
}

// meshOwnerGetAuthorized: the request carries a whitelisted key's kind
// 24242 "get" for sha256, unexpired and validly signed: what khatru checks
// before meshBlobRejectGet lets the owner read an unposted blob.
func meshOwnerGetAuthorized(r *http.Request, sha256 string) bool {
	token := r.Header.Get("Authorization")
	if !strings.HasPrefix(token, "Nostr ") {
		return false
	}
	raw, err := decodeNostrAuthToken(token[6:])
	if err != nil {
		return false
	}
	var ev nostr.Event
	if json.Unmarshal(raw, &ev) != nil || ev.Kind != 24242 {
		return false
	}
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return false
	}
	if authExpiration(&ev) <= time.Now().Unix() ||
		ev.Tags.FindWithValue("t", "get") == nil || ev.Tags.FindWithValue("x", sha256) == nil {
		return false
	}
	if !ev.CheckID() {
		return false
	}
	ok, _ := ev.CheckSignature()
	return ok
}
