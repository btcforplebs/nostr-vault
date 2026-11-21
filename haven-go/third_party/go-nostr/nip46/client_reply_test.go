package nip46

import (
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
	"github.com/puzpuzpuz/xsync/v3"
)

// Anyone can tag the client key with a kind-24133 event. A malformed one
// must be dropped, not panic the listener goroutine (that ends the app).
func TestHandleReplyDropsMalformedEvent(t *testing.T) {
	b := &BunkerClient{
		listeners:     xsync.NewMapOf[string, chan Response](),
		expectingAuth: xsync.NewMapOf[string, struct{}](),
		onAuth:        func(string) {},
	}
	for _, content := range []string{"AAAA?iv=AAAA", "AAAA?iv=AAAAAAAAAAAAAAAAAAAAAA==", "", "garbage"} {
		b.handleReply(&nostr.Event{Kind: nostr.KindNostrConnect, Content: content}, make([]byte, 32), [32]byte{})
	}
	// A panic inside is stopped too: a closed listener channel.
	ch := make(chan Response)
	close(ch)
	b.listeners.Store("x", ch)
	secret := make([]byte, 32)
	content, err := nip04.Encrypt(`{"id":"x","result":"ok"}`, secret)
	if err != nil {
		t.Fatal(err)
	}
	b.handleReply(&nostr.Event{Kind: nostr.KindNostrConnect, Content: content}, secret, [32]byte{})
}
