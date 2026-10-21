package main

import (
	"testing"
	"time"
)

// A relay that delivers events and then drops the socket within seconds must
// back off to the cap, not retry every second.
func TestFlappingSubscriptionBacksOff(t *testing.T) {
	var wait, next time.Duration
	for range 10 {
		wait, next = nextResubscribeBackoff(next, 2*time.Second)
	}
	if wait != maxResubscribeBackoff {
		t.Fatalf("after 10 quick closes the wait is %v, want %v", wait, maxResubscribeBackoff)
	}
}

func TestHealthySubscriptionResetsBackoff(t *testing.T) {
	wait, next := nextResubscribeBackoff(maxResubscribeBackoff, healthySubscription)
	if wait != time.Second || next != 2*time.Second {
		t.Fatalf("after a healthy subscription: wait %v next %v, want 1s 2s", wait, next)
	}
}

func TestFirstCloseWaitsOneSecond(t *testing.T) {
	if wait, _ := nextResubscribeBackoff(0, 0); wait != time.Second {
		t.Fatalf("first wait %v, want 1s", wait)
	}
}
