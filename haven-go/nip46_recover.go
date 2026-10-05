package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
	"github.com/nbd-wtf/go-nostr/nip46"
)

// signerReplies is what signWithRecovery needs from a signer session.
type signerReplies struct {
	client   *nip46.BunkerClient
	pool     *nostr.SimplePool
	signer   string
	relays   []string
	clientSK string
}

// How often a waiting sign_event looks for its reply on the relays itself.
var signRecoveryInterval = 3 * time.Second

// signWithRecovery runs sign_event, and meanwhile reads the signer's replies
// straight off the relays.
//
// go-nostr's BunkerClient hears replies only through its one live
// subscription. When the socket drops (iOS suspends the app while the person
// is in Clave approving), the pool waits 3 s and more before resubscribing,
// and resubscribes with since=now. A reply the signer sent in that gap is
// never delivered: the request sat out its full 90 s timeout while the
// "Approve in your signer" banner stayed up, long after the signer was done.
//
// The reply's request id is internal to BunkerClient, so a recovered reply is
// matched on content instead: the signed event must be exactly the one asked
// for (checkRemoteSigned), which no other reply can satisfy.
func signWithRecovery(ctx context.Context, sess signerReplies, evt *nostr.Event) error {
	if sess.signer == "" || len(sess.relays) == 0 || sess.clientSK == "" || sess.pool == nil {
		return sess.client.SignEvent(ctx, evt)
	}
	req := *evt
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	signed := *evt
	done := make(chan error, 1)
	go func() { done <- sess.client.SignEvent(ctx, &signed) }()

	// Replies older than the request can't answer it; a little slack for
	// clock skew between this phone and the signer.
	since := nostr.Timestamp(time.Now().Add(-30 * time.Second).Unix())
	ticker := time.NewTicker(signRecoveryInterval)
	defer ticker.Stop()
	for {
		select {
		case err := <-done:
			if err == nil {
				*evt = signed
			}
			return err
		case <-ticker.C:
			if got := fetchSignReply(ctx, sess, req, since); got != nil {
				log.Printf("NIP46SignEventC: reply recovered from relay (missed by the live subscription) kind=%d", got.Kind)
				*evt = *got
				return nil
			}
		}
	}
}

// fetchSignReply queries the session's relays for the signer's replies to
// this client and returns the one that signs `req`, if any.
func fetchSignReply(ctx context.Context, sess signerReplies, req nostr.Event, since nostr.Timestamp) *nostr.Event {
	clientPK, err := nostr.GetPublicKey(sess.clientSK)
	if err != nil {
		return nil
	}
	key, err := nip44.GenerateConversationKey(sess.signer, sess.clientSK)
	if err != nil {
		return nil
	}
	fctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	for ie := range sess.pool.FetchMany(fctx, sess.relays, nostr.Filter{
		Kinds:   []int{nostr.KindNostrConnect},
		Authors: []string{sess.signer},
		Tags:    nostr.TagMap{"p": []string{clientPK}},
		Since:   &since,
	}) {
		if got := signReplyFor(ie.Event, key, req); got != nil {
			return got
		}
	}
	return nil
}

// signReplyFor decrypts one signer reply and returns the signed event in it
// when that event is exactly `req`, signed.
func signReplyFor(ev *nostr.Event, key [32]byte, req nostr.Event) *nostr.Event {
	if ev == nil {
		return nil
	}
	plain, err := nip44.Decrypt(ev.Content, key)
	if err != nil {
		return nil
	}
	var resp nip46.Response
	if json.Unmarshal([]byte(plain), &resp) != nil || resp.Error != "" || resp.Result == "" {
		return nil
	}
	var got nostr.Event
	if json.Unmarshal([]byte(resp.Result), &got) != nil {
		return nil
	}
	if checkRemoteSigned(req, got, req.PubKey) != nil {
		return nil
	}
	return &got
}
