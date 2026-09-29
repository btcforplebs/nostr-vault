//go:build !cshared

package main

import (
	"encoding/json"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
)

// signerAnswer builds the kind 24133 event a signer publishes back to the
// client, with `result` as given.
func signerAnswer(t *testing.T, signerSK, clientPK, result string) *nostr.Event {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"id": "x", "result": result})
	key, err := nip44.GenerateConversationKey(clientPK, signerSK)
	if err != nil {
		t.Fatal(err)
	}
	content, err := nip44.Encrypt(string(body), key)
	if err != nil {
		t.Fatal(err)
	}
	ev := &nostr.Event{
		Kind:      nostr.KindNostrConnect,
		CreatedAt: nostr.Now(),
		Tags:      nostr.Tags{{"p", clientPK}},
		Content:   content,
	}
	if err := ev.Sign(signerSK); err != nil {
		t.Fatal(err)
	}
	return ev
}

func TestNostrConnectAck(t *testing.T) {
	clientSK := nostr.GeneratePrivateKey()
	clientPK, _ := nostr.GetPublicKey(clientSK)
	signerSK := nostr.GeneratePrivateKey()
	signerPK, _ := nostr.GetPublicKey(signerSK)
	const secret = "s3cret"

	if pk, ok := nostrConnectAck(signerAnswer(t, signerSK, clientPK, secret), clientSK, clientPK, secret); !ok || pk != signerPK {
		t.Fatalf("echoed secret: got %q %v, want signer pubkey", pk, ok)
	}
	multi := `{"echoed_secret":"s3cret","name":"alice","total":2}`
	if pk, ok := nostrConnectAck(signerAnswer(t, signerSK, clientPK, multi), clientSK, clientPK, secret); !ok || pk != signerPK {
		t.Fatalf("multi-account result: got %q %v", pk, ok)
	}
	for _, result := range []string{"ack", "wrong", `{"echoed_secret":"nope"}`, ""} {
		if _, ok := nostrConnectAck(signerAnswer(t, signerSK, clientPK, result), clientSK, clientPK, secret); ok {
			t.Errorf("result %q was accepted; only our secret may pair", result)
		}
	}

	// Tagged to someone else.
	otherPK, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	if _, ok := nostrConnectAck(signerAnswer(t, signerSK, otherPK, secret), clientSK, clientPK, secret); ok {
		t.Error("an answer tagged to another client was accepted")
	}
	// Tampered after signing.
	ev := signerAnswer(t, signerSK, clientPK, secret)
	ev.CreatedAt++
	if _, ok := nostrConnectAck(ev, clientSK, clientPK, secret); ok {
		t.Error("an event with a broken signature was accepted")
	}
}
