package main

import (
	"bytes"
	"context"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// Tagged notes used to be one un-paged request per filter, so a relay's
// answer cap (here 300) was all of years of replies anyone got (Tidy import
// audit, item 3). Now they are paged like the owner's own notes.
func TestMoveInTaggedNotesArePagedPastTheRelayCap(t *testing.T) {
	owner, _ := moveInSetup(t, 100, "wss://capped.example")
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	friend := newTestKey(t)
	inbox := newTestBackend(t, "inbox")
	chat := newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })

	now := time.Now()
	held := make([]*nostr.Event, 1200)
	for i := range held {
		ev := friend.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Timestamp(now.Add(-time.Duration(i) * time.Hour).Unix()), Tags: nostr.Tags{{"p", owner.pk}}, Content: "a reply to you"})
		held[i] = &ev
	}
	r := &pagingRelay{held: held, cap: 300}
	var mu sync.Mutex
	prev := importPage
	importPage = func(_ context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		return r.answer(f)
	}
	t.Cleanup(func() { importPage = prev })

	importTaggedNotes(context.Background())

	if got := count(t, inbox, friend.pk); got != 1200 {
		t.Fatalf("inbox has %d of 1200 tagged notes: the relay's cap of 300 cut them", got)
	}
}

// "Copy from my other vault" adds that vault as one more seed; when it can't
// be reached the import says so (it used to carry on without a word; Tron,
// import audit item 10), and the mesh URL's token never reaches the log.
func TestImportSaysWhenTheOtherVaultIsNotReached(t *testing.T) {
	_, _ = moveInSetup(t, 10, "ws://127.0.0.1:1/secret-mesh-token")
	var buf bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prevOut) })

	ensureImportRelays()

	out := buf.String()
	if !strings.Contains(out, "other vault not reached") {
		t.Fatalf("an unreachable other vault was not reported:\n%s", out)
	}
	if strings.Contains(out, "secret-mesh-token") {
		t.Fatalf("the mesh token reached the log:\n%s", out)
	}
	if !otherVaultSeed("ws://192.168.1.20:3355") || otherVaultSeed("wss://relay.damus.io") {
		t.Fatal("other-vault seeds: LAN yes, public relay no")
	}
}
