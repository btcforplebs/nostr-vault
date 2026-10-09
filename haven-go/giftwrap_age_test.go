package main

import (
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The plain age gate is what keeps startup quiet: backlog older than
// NotifyMaxAgeHours never notifies, gift wraps included.
func TestIsNotifyableAgeStaysStrictForBacklog(t *testing.T) {
	setupSyncConfig(hexid('0')) // NotifyMaxAgeHours=24
	if isNotifyableAge(aged(nostr.KindGiftWrap, 40*time.Hour)) {
		t.Fatal("40h-old gift wrap from backlog must not notify (startup storm)")
	}
	if !isNotifyableAge(aged(nostr.KindGiftWrap, time.Hour)) {
		t.Fatal("1h-old gift wrap must notify")
	}
}

// A gift wrap that arrives live was just sent, but its created_at is randomized
// up to 2 days into the past — so it can look 40h old and must still notify.
func TestIsNotifyableLiveGiftWrapAllowsBackdate(t *testing.T) {
	setupSyncConfig(hexid('0')) // NotifyMaxAgeHours=24
	cases := []struct {
		age  time.Duration
		want bool
	}{
		{time.Hour, true},
		{40 * time.Hour, true},
		{71 * time.Hour, true},
		{100 * time.Hour, false},
	}
	for _, c := range cases {
		if got := isNotifyableLiveGiftWrap(aged(nostr.KindGiftWrap, c.age)); got != c.want {
			t.Errorf("age %v: got %v, want %v", c.age, got, c.want)
		}
	}
}

func aged(kind int, age time.Duration) *nostr.Event {
	return &nostr.Event{Kind: kind, CreatedAt: nostr.Timestamp(time.Now().Add(-age).Unix())}
}
