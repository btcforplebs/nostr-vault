package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Sync rework M1 (RESEARCH/NV_SYNC_REWORK_BUILD_PLAN_2026_11_12.md §1): the
// mesh door answers REQ on the outbox like the https Haven, with mesh-only
// caps on top.

// outboxReadsServer serves an outbox wired as in production
// (wireOutboxReads) over db; mesh marks every connection as the mesh door.
func outboxReadsServer(t *testing.T, db DBBackend, mesh bool) string {
	t.Helper()
	url, _, _ := outboxReadsRelay(t, db, mesh)
	return url
}

// outboxReadsRelay is outboxReadsServer that also gives the relay and the
// server side of the latest connection (to count its listeners).
func outboxReadsRelay(t *testing.T, db DBBackend, mesh bool) (string, *khatru.Relay, func() *khatru.WebSocket) {
	t.Helper()
	rl := khatru.NewRelay()
	rl.Negentropy = true // on by default in the vault (config.go)
	var mu sync.Mutex
	var last *khatru.WebSocket
	rl.OnConnect = append(rl.OnConnect, func(ctx context.Context) {
		mu.Lock()
		last = khatru.GetConnection(ctx)
		mu.Unlock()
	})
	wireOutboxReads(rl, db, OutboxRelayLimits{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if mesh {
			r = markMesh(r)
		}
		rl.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http"), rl, func() *khatru.WebSocket {
		mu.Lock()
		defer mu.Unlock()
		return last
	}
}

func storeNotes(t *testing.T, db DBBackend, sk string, n, contentBytes int) {
	t.Helper()
	pk, _ := nostr.GetPublicKey(sk)
	ctx := context.Background()
	for i := 0; i < n; i++ {
		ev := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Timestamp(1_700_000_000 + i),
			Content: fmt.Sprintf("%d %s", i, strings.Repeat("x", contentBytes))}
		ev.Sign(sk)
		if err := db.SaveEvent(ctx, ev); err != nil {
			t.Fatal(err)
		}
	}
}

func meshQuery(t *testing.T, url string, f nostr.Filter) ([]*nostr.Event, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	sub, err := r.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		t.Fatal(err)
	}
	var got []*nostr.Event
	for {
		select {
		case ev := <-sub.Events:
			got = append(got, ev)
		case <-sub.EndOfStoredEvents:
			return got, ""
		case reason := <-sub.ClosedReason:
			return got, reason
		case <-ctx.Done():
			t.Fatal("no EOSE")
		}
	}
}

// The outbox answers a stranger's REQ over the mesh, as it does over https.
func TestMeshDoorAnswersOutboxREQ(t *testing.T) {
	_, pk := withOwner(t)
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ = nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 3, 10)
	got, closed := meshQuery(t, outboxReadsServer(t, db, true), nostr.Filter{Authors: []string{pk}, Kinds: []int{1}})
	if closed != "" || len(got) != 3 {
		t.Fatalf("mesh REQ: %d events, closed %q; want 3", len(got), closed)
	}
}

// At most meshMaxLimit events per filter over the mesh, whatever the filter
// asks (no limit, or a bigger one). https is unchanged.
func TestMeshDoorCapsTheLimit(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, meshMaxLimit+20, 10)
	for _, limit := range []int{0, 10_000} {
		got, closed := meshQuery(t, outboxReadsServer(t, db, true), nostr.Filter{Authors: []string{pk}, Limit: limit})
		if closed != "" || len(got) > meshMaxLimit || len(got) == 0 {
			t.Fatalf("limit %d: %d events over the mesh, closed %q; want 1..%d", limit, len(got), closed, meshMaxLimit)
		}
	}
	got, _ := meshQuery(t, outboxReadsServer(t, db, false), nostr.Filter{Authors: []string{pk}, Limit: 10_000})
	if len(got) <= meshMaxLimit {
		t.Fatalf("https got %d, the mesh cap must not apply there", len(got))
	}
}

// One filter's answer over the mesh stops at meshMaxAnswerBytes.
func TestMeshDoorCapsTheAnswerBytes(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 60, 40_000) // about 2.4 MB
	got, closed := meshQuery(t, outboxReadsServer(t, db, true), nostr.Filter{Authors: []string{pk}, Limit: 60})
	total := 0
	for _, ev := range got {
		b, _ := json.Marshal(ev)
		total += len(b)
	}
	if closed != "" || len(got) == 0 || total > meshMaxAnswerBytes+45_000 {
		t.Fatalf("mesh answer: %d events, %d bytes, closed %q; want at most about %d bytes", len(got), total, closed, meshMaxAnswerBytes)
	}
}

// rawConn opens a websocket to url and gives a send and a read of raw frames.
func rawConn(t *testing.T, url string) (*nostr.Relay, func(string)) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	r, err := nostr.RelayConnect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r, func(msg string) {
		if err := <-r.Write([]byte(msg)); err != nil {
			t.Fatal(err)
		}
	}
}

func waitListeners(rl *khatru.Relay, ws func() *khatru.WebSocket) int {
	// Every REQ handler runs in its own goroutine: give them time to finish.
	n, same := -1, 0
	for i := 0; i < 200 && same < 10; i++ {
		time.Sleep(10 * time.Millisecond)
		c := rl.ListenerCount(ws())
		if c == n {
			same++
		} else {
			n, same = c, 0
		}
	}
	return n
}

// Tron's review of #1963, row by row: one mesh connection never holds more
// than meshMaxSubscriptions open listeners, however the REQs come.
func TestMeshDoorCapsOpenListeners(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 1, 10)
	filter := fmt.Sprintf(`{"authors":["%s"],"limit":0}`, pk)
	rows := map[string]func(send func(string)){
		"500 REQs, distinct ids, limit 0": func(send func(string)) {
			for i := 0; i < 500; i++ {
				send(fmt.Sprintf(`["REQ","s%d",%s]`, i, filter))
			}
		},
		"500 REQs, one id": func(send func(string)) {
			for i := 0; i < 500; i++ {
				send(fmt.Sprintf(`["REQ","same",%s]`, filter))
			}
		},
		"300 REQs at once": func(send func(string)) {
			var wg sync.WaitGroup
			for i := 0; i < 300; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					send(fmt.Sprintf(`["REQ","b%d",{"authors":["%s"]}]`, i, pk))
				}(i)
			}
			wg.Wait()
		},
	}
	for name, run := range rows {
		t.Run(name, func(t *testing.T) {
			url, rl, ws := outboxReadsRelay(t, db, true)
			_, send := rawConn(t, url)
			run(send)
			if n := waitListeners(rl, ws); n > meshMaxSubscriptions || n == 0 {
				t.Fatalf("one mesh connection holds %d listeners, want 1..%d", n, meshMaxSubscriptions)
			}
		})
	}
	// Closing makes room again.
	url := outboxReadsServer(t, db, true)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	// open subscribes and reads until EOSE (true) or CLOSED (false).
	open := func() (*nostr.Subscription, bool) {
		sub, err := r.Subscribe(ctx, nostr.Filters{{Authors: []string{pk}}})
		if err != nil {
			t.Fatal(err)
		}
		for {
			select {
			case <-sub.Events:
			case <-sub.EndOfStoredEvents:
				return sub, true
			case <-sub.ClosedReason:
				return sub, false
			case <-ctx.Done():
				t.Fatal("no answer")
			}
		}
	}
	var subs []*nostr.Subscription
	refused := false
	for i := 0; i <= meshMaxSubscriptions; i++ {
		if sub, ok := open(); ok {
			subs = append(subs, sub)
		} else {
			refused = true
		}
	}
	if !refused || len(subs) != meshMaxSubscriptions {
		t.Fatalf("%d open before a refusal (refused %v), want %d", len(subs), refused, meshMaxSubscriptions)
	}
	subs[0].Unsub()
	time.Sleep(100 * time.Millisecond)
	if _, ok := open(); !ok {
		t.Fatal("after a CLOSE there was no room")
	}
}

// One REQ with more than meshMaxFilters filters is refused: per-filter caps
// times 50 filters let one REQ send 50 MB.
func TestMeshDoorCapsFiltersPerREQ(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 1, 10)
	filters := make(nostr.Filters, meshMaxFilters+1)
	for i := range filters {
		filters[i] = nostr.Filter{Authors: []string{pk}}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, outboxReadsServer(t, db, true))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	sub, err := r.Subscribe(ctx, filters)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-sub.ClosedReason:
		if !strings.Contains(reason, "filters") {
			t.Fatalf("refused for %q", reason)
		}
	case <-sub.Events:
		t.Fatal("a REQ with too many filters was answered")
	case <-sub.EndOfStoredEvents:
		t.Fatal("a REQ with too many filters was answered")
	case <-ctx.Done():
		t.Fatal("no answer")
	}
	if got, closed := meshQuery(t, outboxReadsServer(t, db, true), nostr.Filter{Authors: []string{pk}}); closed != "" || len(got) != 1 {
		t.Fatalf("a normal REQ after: %d events, closed %q", len(got), closed)
	}
}

// Tron's review of #1963: a NEG-OPEN over the mesh crashed the relay (an
// unguarded subscription id). It is refused, and the relay keeps serving.
func TestMeshDoorRefusesNegentropy(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 1, 10)
	url := outboxReadsServer(t, db, true)
	c, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.WriteMessage(websocket.TextMessage, []byte(`["NEG-OPEN","n1",{"kinds":[1]},"6100000200"]`)); err != nil {
		t.Fatal(err)
	}
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, msg, err := c.ReadMessage()
	if err != nil || !strings.HasPrefix(string(msg), `["NEG-ERROR","n1"`) || !strings.Contains(string(msg), "negentropy") {
		t.Fatalf("NEG-OPEN over the mesh answered %q (%v), want NEG-ERROR: no negentropy over the mesh", msg, err)
	}
	if got, closed := meshQuery(t, url, nostr.Filter{Authors: []string{pk}}); closed != "" || len(got) != 1 {
		t.Fatalf("after a NEG-OPEN the relay answers %d events, closed %q", len(got), closed)
	}
}

// COUNT stays closed over the mesh.
func TestMeshDoorRefusesCount(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 3, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, outboxReadsServer(t, db, true))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	n, _, err := r.Count(ctx, nostr.Filters{{Authors: []string{pk}}})
	if err == nil && n > 0 {
		t.Fatalf("COUNT over the mesh answered %d", n)
	}
}

// Brought-over accounts stay hidden from a stranger over the mesh, as over
// https; the owner's own notes are served.
func TestMeshDoorHidesBroughtOverAccounts(t *testing.T) {
	t.Chdir(t.TempDir())
	ownerSK, ownerPK := withOwner(t)
	db := withOutbox(t)
	broughtSK := nostr.GeneratePrivateKey()
	broughtPK, _ := nostr.GetPublicKey(broughtSK)
	npub, _ := nip19.EncodePublicKey(broughtPK)
	raw, _ := json.Marshal(copyBroughtList{V: 1, Accounts: []string{npub}})
	if err := os.WriteFile(copyBroughtFile, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	storeNotes(t, db, ownerSK, 2, 10)
	storeNotes(t, db, broughtSK, 2, 10)
	url := outboxReadsServer(t, db, true)
	got, closed := meshQuery(t, url, nostr.Filter{Authors: []string{ownerPK, broughtPK}, Kinds: []int{1}})
	if closed != "" {
		t.Fatalf("closed %q", closed)
	}
	for _, ev := range got {
		if ev.PubKey == broughtPK {
			t.Fatal("a brought-over account's note went to a stranger over the mesh")
		}
	}
	if len(got) != 2 {
		t.Fatalf("got %d of the owner's 2 notes", len(got))
	}
}

// Tron's note on #1960: a note with a follow's signed delete in the feed
// cache is refused when an app writes it to /feed.
func TestFeedRouteRefusesADeletedNote(t *testing.T) {
	saved := feedDB
	t.Cleanup(func() { feedDB = saved })
	db := newTestBackend(t, "feed")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	feedDB = db
	sk := nostr.GeneratePrivateKey()
	note := &nostr.Event{Kind: 1, CreatedAt: nostr.Now() - 60, Content: "deleted"}
	note.Sign(sk)
	if err := db.SaveEvent(context.Background(), signedDelete(t, sk, note)); err != nil {
		t.Fatal(err)
	}
	rejected := false
	for _, rule := range feedWriteRules(db) {
		if r, _ := rule(context.Background(), note); r {
			rejected = true
		}
	}
	if !rejected {
		t.Fatal("/feed takes a note its author deleted")
	}
}

// Tron's reproduction on #1963, through the whole relay and the real mesh
// door: a NEG-OPEN is a NEG-ERROR, not a crash.
func TestMeshDoorNegOpenThroughTheDoor(t *testing.T) {
	startHaven(t)
	saved := outboxRelay.Negentropy
	outboxRelay.Negentropy = true // on by default (config.go)
	t.Cleanup(func() { outboxRelay.Negentropy = saved })
	door := startMeshDoor(t)
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(door, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.WriteMessage(websocket.TextMessage, []byte(`["NEG-OPEN","n1",{"kinds":[1]},"6100000200"]`)); err != nil {
		t.Fatal(err)
	}
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, msg, err := c.ReadMessage()
	if err != nil || !strings.HasPrefix(string(msg), `["NEG-ERROR","n1"`) {
		t.Fatalf("NEG-OPEN through the door answered %q (%v)", msg, err)
	}
}
