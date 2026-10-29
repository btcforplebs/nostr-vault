package main

import (
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// Watermarks and rejects written by one relay start are read by the next.
func TestSyncStateSurvivesRestart(t *testing.T) {
	appfs := afero.NewMemMapFs()
	now := time.Now().Unix()
	s := openSyncState(appfs, "db/inbox_sync_state.json")
	s.setMark("inbox", now-300)
	rj := &tempRejects{}
	rj.add("aa", nostr.Timestamp(now-100), "pk1")
	rj.add("old", nostr.Timestamp(now-90*24*3600), "pk2")
	s.keepRejects(rj)
	s.save()

	r := openSyncState(appfs, "db/inbox_sync_state.json")
	if got := r.mark("inbox", now-86400, now-30*86400); got != now-300 {
		t.Fatalf("inbox mark after restart = %d, want %d", got, now-300)
	}
	back := &tempRejects{}
	r.loadRejects(back, nostr.Timestamp(now-30*86400))
	if _, ok := back.m.Load("aa"); !ok {
		t.Fatal("reject lost on restart")
	}
	if _, ok := back.m.Load("old"); ok {
		t.Fatal("reject older than the window came back")
	}
}

func TestSyncStateMarkClamps(t *testing.T) {
	s := openSyncState(afero.NewMemMapFs(), "s.json")
	now := time.Now().Unix()
	if got := s.mark("x", 42, 0); got != 42 {
		t.Fatalf("missing mark = %d, want the default", got)
	}
	s.setMark("x", now-100*86400)
	if got := s.mark("x", 42, now-30*86400); got != now-30*86400 {
		t.Fatalf("too-old mark = %d, want the floor", got)
	}
	s.setMark("x", now+86400)
	if got := s.mark("x", 42, 0); got > time.Now().Unix() {
		t.Fatalf("future mark %d not held to now", got)
	}
	var nilState *syncState
	if got := nilState.mark("x", 7, 0); got != 7 {
		t.Fatalf("nil state mark = %d", got)
	}
	nilState.save()
}

// An unreadable file starts fresh instead of stopping the relay.
func TestSyncStateCorruptFile(t *testing.T) {
	appfs := afero.NewMemMapFs()
	s := openSyncState(appfs, "s.json")
	afero.WriteFile(appfs, s.path, []byte("{not json"), 0o600)
	if got := openSyncState(appfs, "s.json").mark("inbox", 5, 0); got != 5 {
		t.Fatalf("corrupt file gave mark %d", got)
	}
}

// After the first plain pull of a start, the inbox pull starts at the
// watermark, not two days back.
func TestFallbackInboxSinceWidensOnlyOnce(t *testing.T) {
	now := time.Now()
	wm := now.Add(-15 * time.Minute).Unix()
	floor := nostr.Timestamp(now.Add(-giftWrapBackdateSlack).Unix())
	if got := fallbackInboxSince(wm, true, now); got != floor {
		t.Fatalf("first pull since %d, want the gift-wrap floor %d", got, floor)
	}
	if got := fallbackInboxSince(wm, false, now); got != nostr.Timestamp(wm-60) {
		t.Fatalf("later pull since %d, want watermark-60 %d", got, wm-60)
	}
	// A watermark older than the floor is never narrowed.
	old := now.Add(-5 * 24 * time.Hour).Unix()
	if got := fallbackInboxSince(old, true, now); got != nostr.Timestamp(old-60) {
		t.Fatalf("old watermark since %d, want %d", got, old-60)
	}
}

// The given-zaps pull covers the whole window once, then only since the last
// finished round.
func TestGivenZapsSinceUsesSavedMark(t *testing.T) {
	s := openSyncState(afero.NewMemMapFs(), "s.json")
	window := nostr.Timestamp(time.Now().Add(-32 * 24 * time.Hour).Unix())
	if got := givenZapsSince(s, window); got != window {
		t.Fatalf("first pull since %d, want the window %d", got, window)
	}
	last := time.Now().Add(-15 * time.Minute).Unix()
	s.setMark("given_zaps", last)
	if got := givenZapsSince(s, window); got != nostr.Timestamp(last-600) {
		t.Fatalf("later pull since %d, want %d", got, last-600)
	}
}
