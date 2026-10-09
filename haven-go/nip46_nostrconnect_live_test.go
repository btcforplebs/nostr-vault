//go:build integration

package main

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
)

// TestNostrConnectAnswerReplays is the "approved in Clave while this app was
// suspended" case against the real relay: the signer's answer is published
// BEFORE anyone is listening, and reading from the request's start time must
// still find it. Run: go test -tags integration -run TestNostrConnectAnswerReplays .
func TestNostrConnectAnswerReplays(t *testing.T) {
	const relayURL = "wss://relay.powr.build"
	clientSK := nostr.GeneratePrivateKey()
	clientPK, _ := nostr.GetPublicKey(clientSK)
	signerSK := nostr.GeneratePrivateKey()
	signerPK, _ := nostr.GetPublicKey(signerSK)
	secret := "live-" + clientPK[:8]
	startedAt := nostr.Now() - 5

	body, _ := json.Marshal(map[string]string{"id": "x", "result": secret})
	key, _ := nip44.GenerateConversationKey(clientPK, signerSK)
	content, _ := nip44.Encrypt(string(body), key)
	answer := nostr.Event{Kind: nostr.KindNostrConnect, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", clientPK}}, Content: content}
	if err := answer.Sign(signerSK); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	relay, err := nostr.RelayConnect(ctx, relayURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := relay.Publish(ctx, answer); err != nil {
		t.Fatalf("publish: %v", err)
	}
	relay.Close()
	time.Sleep(2 * time.Second) // nobody listening while "suspended"

	pool := nostr.NewSimplePool(ctx)
	events := pool.SubscribeMany(ctx, []string{relayURL}, nostr.Filter{
		Kinds: []int{nostr.KindNostrConnect},
		Tags:  nostr.TagMap{"p": []string{clientPK}},
		Since: &startedAt,
	})
	for ie := range events {
		if pk, ok := nostrConnectAck(ie.Event, clientSK, clientPK, secret); ok {
			if pk != signerPK {
				t.Fatalf("got signer %s, want %s", pk, signerPK)
			}
			return
		}
	}
	t.Fatal("the answer published before we listened was not replayed")
}
