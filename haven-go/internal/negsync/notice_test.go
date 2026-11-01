package negsync

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
)

// emptyStore is a local store with nothing in it.
type emptyStore struct{}

func (emptyStore) QuerySync(context.Context, nostr.Filter) ([]*nostr.Event, error) { return nil, nil }
func (emptyStore) QueryEvents(context.Context, nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	close(ch)
	return ch, nil
}
func (emptyStore) Publish(context.Context, nostr.Event) error { return nil }

// noticeRelay answers NEG-OPEN with a NOTICE, the way primal and damus do.
func noticeRelay(t *testing.T, notice string) string {
	t.Helper()
	up := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			_, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			if strings.HasPrefix(string(msg), `["NEG-OPEN"`) {
				c.WriteMessage(websocket.TextMessage, []byte(`["NOTICE",`+notice+`]`))
			}
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func TestNegentropyNoticeEndsHandshakeAtOnce(t *testing.T) {
	url := noticeRelay(t, `"ERROR: negentropy disabled"`)
	start := time.Now()
	_, err := Sync(context.Background(), emptyStore{}, url, nostr.Filter{Kinds: []int{1}}, Down)
	if !errors.Is(err, ErrUnsupported) {
		t.Fatalf("want ErrUnsupported, got %v", err)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("took %v: waited out the handshake instead of reading the NOTICE", took)
	}
}

func TestIsUnsupportedNotice(t *testing.T) {
	for notice, want := range map[string]bool{
		"ERROR: negentropy disabled":           true,
		"negentropy error: not enabled":        true,
		"ERROR: bad msg: unknown cmd NEG-OPEN": true,
		"Unknown command: NEG-OPEN":            true,
		"restricted: rate limited":             false,
		"welcome to the relay":                 false,
	} {
		if got := IsUnsupportedNotice(notice); got != want {
			t.Errorf("IsUnsupportedNotice(%q) = %v, want %v", notice, got, want)
		}
	}
}
