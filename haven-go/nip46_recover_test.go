package main

import (
	"encoding/json"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
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

	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "a", Result: string(signedJSON)}), replyKeys{nip44: key}, req); got == nil || got.ID != signed.ID {
		t.Fatalf("the reply that signs the request was not taken: %v", got)
	}
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "b", Result: string(otherJSON)}), replyKeys{nip44: key}, req); got != nil {
		t.Fatalf("a reply for another event was taken as this one's")
	}
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "c", Error: "rejected"}), replyKeys{nip44: key}, req); got != nil {
		t.Fatalf("an error reply was taken as a signature")
	}
	wrongKey, _ := nip44.GenerateConversationKey(userPK, nostr.GeneratePrivateKey())
	if got := signReplyFor(signReply(t, userSK, clientPK, nip46.Response{ID: "d", Result: string(signedJSON)}), replyKeys{nip44: wrongKey}, req); got != nil {
		t.Fatalf("a reply not addressed to this client was read")
	}
}

// A follow list of ~993 accounts, Logen's size: over NIP-44's limit.
func followList(n int, pk string) nostr.Event {
	tags := make(nostr.Tags, 0, n)
	for i := 0; i < n; i++ {
		tags = append(tags, nostr.Tag{"p", nostr.GeneratePrivateKey()})
	}
	return nostr.Event{PubKey: pk, Kind: 3, CreatedAt: nostr.Now(), Tags: tags}
}

func TestOversizedFollowListGoesOverNIP04(t *testing.T) {
	clientSK := nostr.GeneratePrivateKey()
	clientPK, _ := nostr.GetPublicKey(clientSK)
	userSK := nostr.GeneratePrivateKey()
	userPK, _ := nostr.GetPublicKey(userSK)

	if signRequestTooBigForNIP44(followList(100, userPK)) {
		t.Fatal("a 100-follow list was judged too big")
	}
	big := followList(993, userPK)
	if !signRequestTooBigForNIP44(big) {
		t.Fatal("a 993-follow list was judged small enough")
	}
	// The positive control: NIP-44 really refuses this request.
	body, _ := signRequest("x", big)
	k44, _ := nip44.GenerateConversationKey(userPK, clientSK)
	if _, err := nip44.Encrypt(string(body), k44); err == nil {
		t.Fatal("NIP-44 accepted the oversized request; the fallback is unnecessary")
	}

	// The signer can read the NIP-04 request and finds the event in it.
	reqEv, err := buildNIP04SignRequest(big, userPK, clientSK)
	if err != nil {
		t.Fatal(err)
	}
	if reqEv.PubKey != clientPK || reqEv.Kind != nostr.KindNostrConnect || reqEv.Tags.GetFirst([]string{"p", userPK}) == nil {
		t.Fatal("request event is not addressed from the client to the signer")
	}
	signerSecret, _ := nip04.ComputeSharedSecret(clientPK, userSK)
	plain, err := nip04.Decrypt(reqEv.Content, signerSecret)
	if err != nil {
		t.Fatalf("signer can't decrypt the request: %v", err)
	}
	var req nip46.Request
	if err := json.Unmarshal([]byte(plain), &req); err != nil || req.Method != "sign_event" || len(req.Params) != 1 {
		t.Fatalf("bad request: %v %+v", err, req)
	}
	var asked nostr.Event
	if err := json.Unmarshal([]byte(req.Params[0]), &asked); err != nil || len(asked.Tags) != 993 {
		t.Fatalf("event in request: %v, %d tags", err, len(asked.Tags))
	}

	// The signer answers over NIP-04; the reply is found and matched.
	signed := big
	signed.Sign(userSK)
	signedJSON, _ := json.Marshal(signed)
	respBody, _ := json.Marshal(nip46.Response{ID: req.ID, Result: string(signedJSON)})
	respContent, _ := nip04.Encrypt(string(respBody), signerSecret)
	reply := &nostr.Event{Kind: nostr.KindNostrConnect, CreatedAt: nostr.Now(), Content: respContent, Tags: nostr.Tags{{"p", clientPK}}}
	reply.Sign(userSK)
	keys, _ := newReplyKeys(userPK, clientSK)
	if got := signReplyFor(reply, keys, big); got == nil || got.ID != signed.ID {
		t.Fatal("NIP-04 reply was not recovered")
	}
	if got := signReplyFor(reply, replyKeys{nip44: keys.nip44}, big); got != nil {
		t.Fatal("NIP-04 reply decrypted without the NIP-04 key")
	}
}
