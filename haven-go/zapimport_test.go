package main

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// zapPair builds a zap request signed by senderSK and a receipt for it signed
// by serviceSK, tagging the recipient with p and, when tagSender, the sender
// with P.
func zapPair(t *testing.T, senderSK, serviceSK, recipient string, tagSender bool) *nostr.Event {
	t.Helper()
	sender, _ := nostr.GetPublicKey(senderSK)
	req := nostr.Event{Kind: nostr.KindZapRequest, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", recipient}}}
	if err := req.Sign(senderSK); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(req)
	receipt := nostr.Event{Kind: nostr.KindZap, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"p", recipient}, {"description", string(raw)},
	}}
	if tagSender {
		receipt.Tags = append(receipt.Tags, nostr.Tag{"P", sender})
	}
	if err := receipt.Sign(serviceSK); err != nil {
		t.Fatal(err)
	}
	return &receipt
}

func TestZapTrustKeyIsTheZapper(t *testing.T) {
	senderSK, serviceSK := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	sender, _ := nostr.GetPublicKey(senderSK)
	service, _ := nostr.GetPublicKey(serviceSK)
	ev := zapPair(t, senderSK, serviceSK, service, false)

	if got := inboxTrustKey(ev); got != sender {
		t.Fatalf("trust key = %s, want the zapper %s", got, sender)
	}

	// A request whose signature does not hold falls back to the author.
	var req nostr.Event
	_ = json.Unmarshal([]byte(ev.Tags.Find("description")[1]), &req)
	req.Content = "tampered"
	raw, _ := json.Marshal(req)
	ev.Tags = nostr.Tags{{"p", service}, {"description", string(raw)}}
	if got := inboxTrustKey(ev); got != service {
		t.Fatalf("tampered request: trust key = %s, want the receipt author %s", got, service)
	}

	note := &nostr.Event{Kind: nostr.KindTextNote, PubKey: service}
	if got := inboxTrustKey(note); got != service {
		t.Fatalf("note: trust key = %s, want its author", got)
	}
}

func TestGivenZapIsKeptForTheSender(t *testing.T) {
	ownerSK, serviceSK, otherSK := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	owner, _ := nostr.GetPublicKey(ownerSK)
	other, _ := nostr.GetPublicKey(otherSK)
	setupSyncConfig(owner)

	given := zapPair(t, ownerSK, serviceSK, other, true)
	if got := givenZapSender(given); got != owner {
		t.Fatalf("givenZapSender = %q, want owner", got)
	}
	c := classifyInboxEvent(context.Background(), given)
	if !c.accept || c.recipient != owner || c.notify {
		t.Fatalf("classify given zap = %+v, want accepted for owner without a notification", c)
	}

	// Someone else's zap that merely claims P = owner is not the owner's.
	forged := zapPair(t, otherSK, serviceSK, other, false)
	forged.Tags = append(forged.Tags, nostr.Tag{"P", owner})
	if got := givenZapSender(forged); got != "" {
		t.Fatalf("forged P tag accepted as owner's zap")
	}
}
