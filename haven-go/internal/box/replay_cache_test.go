package box

import (
	"fmt"
	"testing"
	"time"
)

func TestReplayCacheOnceThenPrunedInOrder(t *testing.T) {
	c := newReplayCache(0)
	t0 := time.Now()
	for i := 0; i < 200; i++ {
		if c.use(fmt.Sprint(i), t0.Add(time.Duration(i)*time.Millisecond)) != replayFirst {
			t.Fatalf("%d: first use refused", i)
		}
	}
	if c.use("5", t0.Add(200*time.Millisecond)) != replayUsed {
		t.Fatal("a replay within the window was accepted")
	}
	// At t0+2w+100.5ms, ids 0..100 are older than two windows; 101.. are not.
	now := t0.Add(2*authWindow + 100*time.Millisecond + 500*time.Microsecond)
	c.use("new", now)
	if n := c.len(); n != 200-101+1 {
		t.Fatalf("after pruning: %d entries, want %d", n, 200-101+1)
	}
	if c.use("150", now) != replayUsed {
		t.Fatal("a live id was pruned")
	}
}

// Tron #2375: a stranger minting throwaway keys fills only the capped
// strangers cache; members still get through and their replays still fail.
func TestStrangersCannotCrowdOutMembers(t *testing.T) {
	a := NewOwnerAuth("00")
	for i := 0; i < strangerReplayLimit; i++ {
		if first, busy := a.StrangerFirstUse(fmt.Sprint("s", i)); !first || busy {
			t.Fatalf("stranger %d refused early", i)
		}
	}
	if first, busy := a.StrangerFirstUse("one-more"); first || !busy {
		t.Fatalf("over the cap: first=%v busy=%v, want refused as busy", first, busy)
	}
	if !a.FirstUse("owner-1") {
		t.Fatal("the owner was refused while strangers filled their cache")
	}
	if a.FirstUse("owner-1") {
		t.Fatal("the owner's replay was accepted")
	}
	if first, _ := a.StrangerFirstUse("owner-1"); first {
		t.Fatal("a member's used id was accepted again as a stranger's")
	}
	// The strangers' ids expire and the door opens again.
	a.Now = func() time.Time { return time.Now().Add(2*authWindow + time.Second) }
	if first, busy := a.StrangerFirstUse("later"); !first || busy {
		t.Fatalf("after the window: first=%v busy=%v", first, busy)
	}
}

// Through the API: a full strangers cache answers 429, the owner 200.
func TestAccountsStrangerFloodGets429OwnerStillServed(t *testing.T) {
	srv, owner, api, _, _ := accountsAPI(t)
	for i := 0; i < strangerReplayLimit; i++ {
		api.Auth.StrangerFirstUse(fmt.Sprint("flood", i))
	}
	k := newTestKey(t)
	if st, out := call(t, srv, &k, "GET", "/api/box/accounts/me", nil); st != 429 {
		t.Fatalf("stranger over the cap: %d %v, want 429", st, out)
	}
	if st, out := call(t, srv, &owner, "GET", "/api/box/accounts/me", nil); st != 200 {
		t.Fatalf("owner while strangers are capped: %d %v", st, out)
	}
}

func BenchmarkReplayCacheFull(b *testing.B) {
	c := newReplayCache(0)
	t0 := time.Now()
	for i := 0; i < 100000; i++ {
		c.use(fmt.Sprint(i), t0)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.use(fmt.Sprint("b", i), t0)
	}
}
