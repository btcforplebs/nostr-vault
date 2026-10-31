package box

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// testKey is a throwaway key made per test run, never a real account.
type testKey struct{ sk, pk string }

func newTestKey(t *testing.T) testKey {
	t.Helper()
	sk := nostr.GeneratePrivateKey()
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		t.Fatal(err)
	}
	return testKey{sk, pk}
}

// authHeader signs a NIP-98 event for method+url (+body) at time at.
func (k testKey) authHeader(t *testing.T, method, url string, body []byte, at time.Time) string {
	t.Helper()
	tags := nostr.Tags{{"u", url}, {"method", method}}
	if body != nil {
		sum := sha256.Sum256(body)
		tags = append(tags, nostr.Tag{"payload", hex.EncodeToString(sum[:])})
	}
	ev := nostr.Event{Kind: 27235, CreatedAt: nostr.Timestamp(at.Unix()), Tags: tags}
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(b)
}

func (k testKey) sign(t *testing.T, ev nostr.Event) *nostr.Event {
	t.Helper()
	if err := ev.Sign(k.sk); err != nil {
		t.Fatal(err)
	}
	return &ev
}

func mustReq(t *testing.T, r *http.Request, err error) *http.Request {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	return r
}
