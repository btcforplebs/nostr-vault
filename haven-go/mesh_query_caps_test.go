package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

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
	rl := khatru.NewRelay()
	wireOutboxReads(rl, db, OutboxRelayLimits{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if mesh {
			r = markMesh(r)
		}
		rl.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
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

// One mesh connection holds at most meshMaxSubscriptions open; the next is
// refused, and closing one makes room.
func TestMeshDoorCapsOpenSubscriptions(t *testing.T) {
	db := withOutbox(t)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	storeNotes(t, db, sk, 1, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, outboxReadsServer(t, db, true))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	open := func() (*nostr.Subscription, string) {
		sub, err := r.Subscribe(ctx, nostr.Filters{{Authors: []string{pk}}})
		if err != nil {
			t.Fatal(err)
		}
		for {
			select {
			case <-sub.Events:
			case <-sub.EndOfStoredEvents:
				return sub, ""
			case reason := <-sub.ClosedReason:
				return sub, reason
			case <-ctx.Done():
				t.Fatal("no answer")
			}
		}
	}
	var subs []*nostr.Subscription
	for i := 0; i < meshMaxSubscriptions; i++ {
		sub, closed := open()
		if closed != "" {
			t.Fatalf("subscription %d refused: %q", i+1, closed)
		}
		subs = append(subs, sub)
	}
	if _, closed := open(); closed == "" {
		t.Fatalf("subscription %d was not refused", meshMaxSubscriptions+1)
	}
	subs[0].Unsub()
	time.Sleep(100 * time.Millisecond)
	if _, closed := open(); closed != "" {
		t.Fatalf("after a CLOSE there was no room: %q", closed)
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
