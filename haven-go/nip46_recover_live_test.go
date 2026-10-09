//go:build integration

package main

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
	"github.com/nbd-wtf/go-nostr/nip46"
)

// TestSignReplyMissedBySubscription is the lingering "Approve in your signer"
// banner against the real relay: the client's socket drops just before the
// signer answers (iOS suspended the app while the person approved in Clave).
// The pool resubscribes with since=now, so BunkerClient never hears the
// reply. Plain SignEvent must time out (the bug); signWithRecovery must
// return the signed event (the fix).
// Run: go test -tags integration -run TestSignReplyMissedBySubscription -v .
func TestSignReplyMissedBySubscription(t *testing.T) {
	t.Run("plain SignEvent misses it", func(t *testing.T) {
		if err := signAcrossDrop(t, false); err == nil {
			t.Fatal("expected the reply to be missed; the control cannot show the bug")
		}
	})
	t.Run("signWithRecovery finds it", func(t *testing.T) {
		if err := signAcrossDrop(t, true); err != nil {
			t.Fatalf("recovery did not find the reply: %v", err)
		}
	})
}

func signAcrossDrop(t *testing.T, recover bool) error {
	const relayURL = "wss://relay.powr.build"
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()

	clientSK := nostr.GeneratePrivateKey()
	clientPK, _ := nostr.GetPublicKey(clientSK)
	signerSK := nostr.GeneratePrivateKey()
	signerPK, _ := nostr.GetPublicKey(signerSK)
	key, _ := nip44.GenerateConversationKey(clientPK, signerSK)

	pool := nostr.NewSimplePool(ctx)
	client := nip46.NewBunker(ctx, clientSK, signerPK, []string{relayURL}, pool, nil)

	// The signer: answers each sign_event after dropping the client's socket.
	signerRelay, err := nostr.RelayConnect(ctx, relayURL)
	if err != nil {
		t.Fatal(err)
	}
	defer signerRelay.Close()
	now := nostr.Now()
	sub, err := signerRelay.Subscribe(ctx, nostr.Filters{{Kinds: []int{nostr.KindNostrConnect}, Tags: nostr.TagMap{"p": []string{signerPK}}, Since: &now}})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for ev := range sub.Events {
			plain, err := nip44.Decrypt(ev.Content, key)
			if err != nil {
				continue
			}
			var req nip46.Request
			if json.Unmarshal([]byte(plain), &req) != nil || req.Method != "sign_event" {
				continue
			}
			var e nostr.Event
			json.Unmarshal([]byte(req.Params[0]), &e)
			e.PubKey = signerPK
			e.Sign(signerSK)
			out, _ := json.Marshal(e)

			if r, err := pool.EnsureRelay(relayURL); err == nil {
				r.Close() // the phone's socket dies while the person approves
			}
			time.Sleep(300 * time.Millisecond)
			body, _ := json.Marshal(nip46.Response{ID: req.ID, Result: string(out)})
			content, _ := nip44.Encrypt(string(body), key)
			reply := nostr.Event{Kind: nostr.KindNostrConnect, CreatedAt: nostr.Now(), Content: content, Tags: nostr.Tags{{"p", clientPK}}}
			reply.Sign(signerSK)
			signerRelay.Publish(ctx, reply)
		}
	}()
	time.Sleep(2 * time.Second) // let the client's reply subscription open

	evt := nostr.Event{PubKey: signerPK, Kind: 1, CreatedAt: nostr.Now(), Content: "recovery probe", Tags: nostr.Tags{}}
	req := evt
	signCtx, signCancel := context.WithTimeout(ctx, 15*time.Second)
	defer signCancel()
	if recover {
		err = signWithRecovery(signCtx, signerReplies{client: client, pool: pool, signer: signerPK, relays: []string{relayURL}, clientSK: clientSK}, &evt)
	} else {
		err = client.SignEvent(signCtx, &evt)
	}
	if err != nil {
		return err
	}
	return checkRemoteSigned(req, evt, signerPK)
}
