package main

import (
	"encoding/json"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
	"github.com/nbd-wtf/go-nostr/nip46"
)

// signReply builds the signer's encrypted reply carrying `result`.
func signReply(t *testing.T, signerSK, clientPK string, resp nip46.Response) *nostr.Event {
	t.Helper()
	body, _ := json.Marshal(resp)
	key, _ := nip44.GenerateConversationKey(clientPK, signerSK)
	content, err := nip44.Encrypt(string(body), key)
	if err != nil {
		t.Fatal(err)
	}
	ev := &nostr.Event{Kind: nostr.KindNostrConnect, CreatedAt: nostr.Now(), Content: content, Tags: nostr.Tags{{"p", clientPK}}}
	ev.Sign(signerSK)
	return ev
}

func TestSignReplyForMatchesOnlyTheRequestedEvent(t *testing.T) {
	clientSK := nostr.GeneratePrivateKey()
	clientPK, _ := nostr.GetPublicKey(clientSK)
	userSK := nostr.GeneratePrivateKey()
	userPK, _ := nostr.GetPublicKey(userSK)
	key, _ := nip44.GenerateConversationKey(userPK, clientSK)

	req := nostr.Event{PubKey: userPK, Kind: 1, CreatedAt: nostr.Now(), Content: "hello", Tags: nostr.Tags{{"t", "x"}}}
	signed := req
	signed.Sign(userSK)
	signedJSON, _ := json.Marshal(signed)

	other := nostr.Event{PubKey: userPK, Kind: 1, CreatedAt: req.CreatedAt, Content: "a different note", Tags: req.Tags}
	other.Sign(userSK)
	otherJSON, _ := json.Marshal(other)

	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "a", Result: string(signedJSON)}), key, req); got == nil || got.ID != signed.ID {
		t.Fatalf("the reply that signs the request was not taken: %v", got)
	}
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "b", Result: string(otherJSON)}), key, req); got != nil {
		t.Fatalf("a reply for another event was taken as this one's")
	}
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "c", Error: "rejected"}), key, req); got != nil {
		t.Fatalf("an error reply was taken as a signature")
	}
	wrongKey, _ := nip44.GenerateConversationKey(userPK, nostr.GeneratePrivateKey())
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "d", Result: string(signedJSON)}), wrongKey, req); got != nil {
		t.Fatalf("a reply not addressed to this client was read")
	}
}
