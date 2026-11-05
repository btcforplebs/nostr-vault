package main

import (
	"bytes"
	"context"
	"errors"
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

// IMPORT_RESULT (import_result.go) reads its partial reasons from the
// import's own log lines. These are the lines the paged import really prints
// now, captured from real runs, not copied by hand.
func TestImportResultReadsThePagedImportsLines(t *testing.T) {
	var buf bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prevOut) })
	lines := func() []string {
		defer buf.Reset()
		return strings.Split(buf.String(), "\n")
	}
	reasons := func(ls []string) (*importOutcome, string) {
		o := newImportOutcome()
		for _, l := range ls {
			o.observe(l)
		}
		return o, strings.Join(o.partial, ",")
	}

	// A walk cut by its deadline.
	owner, _ := moveInSetup(t, 3650, "wss://slow.example")
	prevDeadline := importWalkDeadline
	importWalkDeadline = 200 * time.Millisecond
	t.Cleanup(func() { importWalkDeadline = prevDeadline })
	prev := importPage
	t.Cleanup(func() { importPage = prev })
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		select {
		case <-time.After(50 * time.Millisecond):
		case <-ctx.Done():
			return nil, false
		}
		ev := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: *f.Since + 1, Content: "slow"})
		return []*nostr.Event{&ev}, true
	}
	importOwnerWindows(context.Background(), []walkRelay{{url: "wss://slow.example", top: time.Now()}}, time.Now().AddDate(0, 0, -3650), []string{owner.pk}, func(*nostr.Event) bool { return true })
	if _, r := reasons(lines()); !strings.Contains(r, "walk_deadline") {
		t.Fatalf("a cut walk read as %q, want walk_deadline", r)
	}

	// A relay that never answers is dropped.
	importPage = func(context.Context, string, nostr.Filter) ([]*nostr.Event, bool) { return nil, false }
	noNegentropy(t)
	importOwnerNotes(context.Background())
	if _, r := reasons(lines()); !strings.Contains(r, "relay_dropped") {
		t.Fatalf("a dropped relay read as %q, want relay_dropped", r)
	}

	// The tagged step cut by its deadline, with its count.
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	inbox, chat := newTestBackend(t, "inbox"), newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })
	prevTagged := importTaggedDeadline
	importTaggedDeadline = 300 * time.Millisecond
	t.Cleanup(func() { importTaggedDeadline = prevTagged })
	friend := newTestKey(t)
	var mu sync.Mutex
	at := nostr.Now()
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		select {
		case <-time.After(40 * time.Millisecond):
		case <-ctx.Done():
			return nil, false
		}
		mu.Lock()
		defer mu.Unlock()
		at--
		ev := friend.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: at, Tags: nostr.Tags{{"p", owner.pk}}, Content: "reply"})
		return []*nostr.Event{&ev}, true // always one more page
	}
	importTaggedNotes(context.Background())
	o, r := reasons(lines())
	if !strings.Contains(r, "tagged_timeout") {
		t.Fatalf("a cut tagged step read as %q, want tagged_timeout", r)
	}
	if o.tagged == 0 {
		t.Fatal("the cut tagged step's count was not read")
	}
}

// resetImportRetries: a fresh retry budget for this test (beginImportRefusalRetries
// joins one still inside importRetryWindow, so tests would share it).
func resetImportRetries(t *testing.T) {
	t.Helper()
	clear := func() {
		importRetryMu.Lock()
		importRetryStarted = time.Time{}
		importRetried = map[string]time.Time{}
		importRetryMu.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

// taggedFixture: inbox and chat stores, a WoT that lets everyone in, and
// importPage answering a reply to the owner every `every`, forever.
func taggedFixture(t *testing.T, every time.Duration) {
	t.Helper()
	owner, _ := moveInSetup(t, 10, "wss://tagged.example")
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	inbox, chat := newTestBackend(t, "inbox"), newTestBackend(t, "chat")
	for _, db := range []DBBackend{inbox, chat} {
		if err := db.Init(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
	}
	savedInbox, savedChat := inboxDB, chatDB
	inboxDB, chatDB = inbox, chat
	t.Cleanup(func() { inboxDB, chatDB = savedInbox, savedChat })
	friend := newTestKey(t)
	var mu sync.Mutex
	at := nostr.Now()
	prev := importPage
	t.Cleanup(func() { importPage = prev })
	importPage = func(ctx context.Context, _ string, f nostr.Filter) ([]*nostr.Event, bool) {
		select {
		case <-time.After(every):
		case <-ctx.Done():
			return nil, false
		}
		mu.Lock()
		defer mu.Unlock()
		at--
		ev := friend.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: at, Tags: nostr.Tags{{"p", owner.pk}}, Content: "reply"})
		return []*nostr.Event{&ev}, true
	}
}

// The tagged step gives up at importTaggedDeadline (~15 min, Logen
// 2026-11-05) whatever IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS says: not
// at its 120 s default, and not later when it is set higher.
func TestTaggedStepGivesUpAtItsOwnDeadline(t *testing.T) {
	taggedFixture(t, 20*time.Millisecond)
	prevDeadline := importTaggedDeadline
	t.Cleanup(func() { importTaggedDeadline = prevDeadline })

	// Set lower (the 120 s default, scaled): it doesn't cut the step short.
	importTaggedDeadline = 600 * time.Millisecond
	config.ImportTaggedNotesFetchTimeoutSeconds = 0
	start := time.Now()
	importTaggedNotes(context.Background())
	if took := time.Since(start); took < 500*time.Millisecond {
		t.Fatalf("the tagged step gave up after %s, before its %s deadline: the config value cut it", took, importTaggedDeadline)
	}

	// Set higher: it doesn't hold the step past its deadline.
	importTaggedDeadline = 300 * time.Millisecond
	config.ImportTaggedNotesFetchTimeoutSeconds = 3600
	bounded, cancel := context.WithTimeout(context.Background(), 5*time.Second) // a regression fails, not hangs
	defer cancel()
	start = time.Now()
	importTaggedNotes(bounded)
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("the tagged step ran %s, past its %s deadline: the config value held it", took, importTaggedDeadline)
	}
}

// Relays that refused us in the same window are retried together: one pause,
// not one after another (Tron, PR 1721).
func TestMoveInWalkRetriesRefusedRelaysTogether(t *testing.T) {
	noNegentropy(t)
	urls := []string{"wss://r1.example", "wss://r2.example", "wss://r3.example"}
	owner, db := moveInSetup(t, 30, urls...)
	resetImportRetries(t)
	beginImportRefusalRetries()
	prevBackoff := importRefusalBackoff
	importRefusalBackoff = 400 * time.Millisecond
	t.Cleanup(func() {
		importRefusalBackoff = prevBackoff
		for _, u := range urls {
			relayBans.Delete(nostr.NormalizeURL(u))
		}
	})
	note := owner.sign(t, nostr.Event{Kind: nostr.KindTextNote, CreatedAt: nostr.Timestamp(time.Now().Add(-48 * time.Hour).Unix()), Content: "in the walk"})
	var mu sync.Mutex
	refused := map[string]bool{}
	prev := importPage
	importPage = func(_ context.Context, url string, f nostr.Filter) ([]*nostr.Event, bool) {
		mu.Lock()
		defer mu.Unlock()
		if relayBanned(url) {
			return nil, false
		}
		if f.Until == nil {
			return nil, false // the lane: silent, so every relay is walked
		}
		if !refused[url] {
			refused[url] = true
			noteRelayRefusal(url, errors.New("rate-limited: slow down"))
			return nil, false
		}
		if f.Matches(&note) {
			return []*nostr.Event{&note}, true
		}
		return nil, true
	}
	t.Cleanup(func() { importPage = prev })

	start := time.Now()
	importOwnerNotes(context.Background())
	took := time.Since(start)

	if got := count(t, db, owner.pk); got != 1 {
		t.Fatalf("vault has %d of the 1 note: the refused relays were not asked again", got)
	}
	if took >= 2*importRefusalBackoff {
		t.Fatalf("3 refused relays took %s: retried one after another (%s each), not together", took, importRefusalBackoff)
	}
}

// An import started while one is running keeps the spent retries: a relay
// that already had its retry gets no second one (and no second pause).
func TestSecondImportKeepsTheSpentRetries(t *testing.T) {
	resetImportRetries(t)
	prevBackoff := importRefusalBackoff
	importRefusalBackoff = 10 * time.Millisecond
	url := "wss://once.example"
	t.Cleanup(func() {
		importRefusalBackoff = prevBackoff
		relayBans.Delete(nostr.NormalizeURL(url))
	})

	beginImportRefusalRetries()
	noteRelayRefusal(url, errors.New("rate-limited: slow down"))
	if !importRetryAfterRefusal(context.Background(), url) {
		t.Fatal("positive control: the first refusal got no retry")
	}
	beginImportRefusalRetries() // a second import starts on top
	noteRelayRefusal(url, errors.New("rate-limited: slow down"))
	if importRetryAfterRefusal(context.Background(), url) {
		t.Fatal("a second import gave a relay a second retry: it reset the spent list")
	}
}
