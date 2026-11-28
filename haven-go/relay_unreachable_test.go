package main

import (
	"errors"
	"testing"
	"time"
)

func newTestHolds(fg *bool, now *time.Time) *unreachableHolds {
	return &unreachableHolds{holds: map[string]unreachableHold{}, now: func() time.Time { return *now }, fg: func() bool { return *fg }}
}

func TestUnreachableHoldDoublesAndCaps(t *testing.T) {
	fg := false
	now := time.Unix(1_800_000_000, 0)
	u := newTestHolds(&fg, &now)
	const r = "wss://relay.example.com"
	if u.remaining(r) != 0 {
		t.Fatal("fresh relay is held")
	}
	want := []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second, 40 * time.Second}
	for i, w := range want {
		u.failed(r)
		if got := u.remaining(r); got != w {
			t.Fatalf("strike %d: hold %s, want %s", i+1, got, w)
		}
	}
	for range 20 {
		u.failed(r)
	}
	if got := u.remaining(r); got != unreachableMaxHoldBg {
		t.Fatalf("background cap: %s", got)
	}
	// Back on screen: the same hold is cut to the on-screen cap at once.
	fg = true
	if got := u.remaining(r); got != unreachableMaxHoldFg {
		t.Fatalf("foreground cap: %s", got)
	}
	now = now.Add(unreachableMaxHoldFg)
	if got := u.remaining(r); got != 0 {
		t.Fatalf("hold outlived the cap: %s", got)
	}
}

func TestUnreachableHoldSharedAcrossURLFormsAndCleared(t *testing.T) {
	fg := true
	now := time.Unix(1_800_000_000, 0)
	u := newTestHolds(&fg, &now)
	u.failed("wss://Relay.Example.com/")
	if u.remaining("wss://relay.example.com") == 0 {
		t.Fatal("normalized form not held")
	}
	u.reached("wss://relay.example.com")
	if u.remaining("wss://relay.example.com") != 0 {
		t.Fatal("reached did not clear the hold")
	}
}

func TestUnreachableHoldForgetsOldFailures(t *testing.T) {
	fg := false
	now := time.Unix(1_800_000_000, 0)
	u := newTestHolds(&fg, &now)
	const r = "wss://relay.example.com"
	for range 6 {
		u.failed(r)
	}
	now = now.Add(unreachableForgetAfter + time.Minute)
	u.failed(r)
	if got := u.remaining(r); got != unreachableFirstHold {
		t.Fatalf("old strikes kept: %s", got)
	}
}

func TestUnreachableNeverHoldsLocalRelays(t *testing.T) {
	fg := false
	now := time.Unix(1_800_000_000, 0)
	u := newTestHolds(&fg, &now)
	for _, r := range []string{"ws://127.0.0.1:3355", "ws://localhost:3355/inbox", "ws://192.168.4.20:3355", "ws://mini.local:3355"} {
		u.failed(r)
		if u.remaining(r) != 0 {
			t.Fatalf("%s held", r)
		}
	}
}

func TestNoteDialFailureSortsRefusalFromUnreachable(t *testing.T) {
	const r = "wss://unreachable-sort.example.com"
	t.Cleanup(func() { relayUnreachable.reached(r); relayBans.Delete("wss://unreachable-sort.example.com") })
	noteDialFailure(r, errors.New("dial tcp: i/o timeout"))
	if relayUnreachable.remaining(r) == 0 {
		t.Fatal("timeout did not hold the relay")
	}
	if relayBanned(r) {
		t.Fatal("timeout banned the relay")
	}
	if unreachableGateErr(r) == nil {
		t.Fatal("gate let a held relay through")
	}
}
