package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
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
	canRecover := sess.signer != "" && len(sess.relays) > 0 && sess.clientSK != "" && sess.pool != nil
	if signRequestTooBigForNIP44(*evt) {
		if !canRecover {
			return errors.New("sign request too large for NIP-44 and no relay route for NIP-04")
		}
		return signViaNIP04(ctx, sess, evt)
	}
	if !canRecover {
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
	keys, err := newReplyKeys(sess.signer, sess.clientSK)
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
		if got := signReplyFor(ie.Event, keys, req); got != nil {
			return got
		}
	}
	return nil
}

// replyKeys decrypts a signer's reply in either encryption: NIP-44, or the
// NIP-04 a signer answers in when the request came that way.
type replyKeys struct {
	nip44 [32]byte
	nip04 []byte
}

func newReplyKeys(signer, clientSK string) (replyKeys, error) {
	k44, err := nip44.GenerateConversationKey(signer, clientSK)
	if err != nil {
		return replyKeys{}, err
	}
	k04, err := nip04.ComputeSharedSecret(signer, clientSK)
	if err != nil {
		return replyKeys{}, err
	}
	return replyKeys{nip44: k44, nip04: k04}, nil
}

// signReplyFor decrypts one signer reply and returns the signed event in it
// when that event is exactly `req`, signed.
func signReplyFor(ev *nostr.Event, keys replyKeys, req nostr.Event) *nostr.Event {
	if ev == nil {
		return nil
	}
	plain, err := nip44.Decrypt(ev.Content, keys.nip44)
	if err != nil && keys.nip04 != nil {
		plain, err = nip04.Decrypt(ev.Content, keys.nip04)
	}
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

// NIP-44 refuses a plaintext over 65535 bytes. A sign_event request carries
// the whole event, escaped into a JSON string, so a follow list of about 900
// accounts or more can never be signed over NIP-44: every follow and unfollow
// failed with "plaintext should be between 1b and 64kB".
const nip44MaxPlaintext = 65535

// signRequest is the sign_event request as go-nostr's BunkerClient builds it.
func signRequest(id string, evt nostr.Event) ([]byte, error) {
	return json.Marshal(nip46.Request{ID: id, Method: "sign_event", Params: []string{evt.String()}})
}

func signRequestTooBigForNIP44(evt nostr.Event) bool {
	// The id BunkerClient uses is a short prefix and a serial; 64 bytes covers it.
	body, err := signRequest("", evt)
	return err == nil && len(body)+64 > nip44MaxPlaintext
}

// buildNIP04SignRequest wraps a sign_event request in NIP-04, which has no
// size limit. NIP-46 signers accepted NIP-04 before NIP-44 existed, and the
// common ones still do; they answer in the encryption they were asked in.
func buildNIP04SignRequest(evt nostr.Event, signer, clientSK string) (nostr.Event, error) {
	body, err := signRequest("nv-"+nostr.GeneratePrivateKey()[:16], evt)
	if err != nil {
		return nostr.Event{}, err
	}
	secret, err := nip04.ComputeSharedSecret(signer, clientSK)
	if err != nil {
		return nostr.Event{}, err
	}
	content, err := nip04.Encrypt(string(body), secret)
	if err != nil {
		return nostr.Event{}, err
	}
	req := nostr.Event{
		Kind:      nostr.KindNostrConnect,
		CreatedAt: nostr.Now(),
		Content:   content,
		Tags:      nostr.Tags{{"p", signer}},
	}
	if err := req.Sign(clientSK); err != nil {
		return nostr.Event{}, err
	}
	return req, nil
}

// signViaNIP04 sends an oversized sign_event over NIP-04 and waits for the
// reply on the session's relays. BunkerClient can't send it (its requests are
// NIP-44 only), and its live subscription would drop the reply as unknown, so
// the reply is found the way signWithRecovery recovers missed ones: by
// content, the signed event must be exactly the one asked for.
func signViaNIP04(ctx context.Context, sess signerReplies, evt *nostr.Event) error {
	req := *evt
	reqEvent, err := buildNIP04SignRequest(req, sess.signer, sess.clientSK)
	if err != nil {
		return err
	}
	since := nostr.Timestamp(time.Now().Add(-30 * time.Second).Unix())
	published := false
	for res := range sess.pool.PublishMany(ctx, sess.relays, reqEvent) {
		if res.Error == nil {
			published = true
		} else {
			log.Printf("NIP46SignEventC: NIP-04 request rejected by %s: %v", res.RelayURL, res.Error)
		}
	}
	if !published {
		return errors.New("no signer relay accepted the NIP-04 sign request")
	}
	log.Printf("NIP46SignEventC: request over NIP-44's 64kB limit, sent over NIP-04 kind=%d", req.Kind)
	ticker := time.NewTicker(signRecoveryInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return errors.New("no reply from the signer to the NIP-04 sign request")
		case <-ticker.C:
			if got := fetchSignReply(ctx, sess, req, since); got != nil {
				*evt = *got
				return nil
			}
		}
	}
}
