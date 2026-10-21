package main

import (
	"encoding/base64"
	"net/http"
	"strings"
)

// decodeNostrAuthToken decodes the base64 part of a Blossom "Nostr <token>"
// header. BUD-11 says base64url without padding; older clients (ours
// included) send standard padded base64. Accept all four forms.
func decodeNostrAuthToken(token string) ([]byte, error) {
	token = strings.TrimSpace(token)
	if strings.ContainsAny(token, "-_") {
		return base64.RawURLEncoding.DecodeString(strings.TrimRight(token, "="))
	}
	return base64.RawStdEncoding.DecodeString(strings.TrimRight(token, "="))
}

// normalizeNostrAuthHeader rewrites a Blossom auth token into padded
// standard base64, the only form khatru v0.19.1 blossom decodes. Without
// this, BUD-11 clients get "404 invalid base64 token" on about two uploads
// in three (barrydeen/haven#138).
func normalizeNostrAuthHeader(r *http.Request) {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Nostr ") {
		return
	}
	raw, err := decodeNostrAuthToken(h[6:])
	if err != nil {
		return // let khatru answer as before
	}
	r.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(raw))
}
