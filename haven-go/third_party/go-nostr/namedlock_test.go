package nostr

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// A name held for a long time (EnsureRelay holds it across a 15 s dial)
// must not block any other name. With 50 hashed buckets, 200 names always
// had one sharing the held name's bucket.
func TestNamedLockDoesNotBlockOtherNames(t *testing.T) {
	unlock := namedLock("wss://stuck.example")
	defer unlock()

	var wg sync.WaitGroup
	done := make(chan struct{})
	for i := range 200 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			namedLock(fmt.Sprintf("wss://relay%d.example", i))()
		}()
	}
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a name was blocked behind another name's lock")
	}
}

// The same name still excludes, and its entry is freed once released.
func TestNamedLockSameNameExcludesAndFrees(t *testing.T) {
	unlock := namedLock("wss://a.example")
	got := make(chan struct{})
	go func() {
		namedLock("wss://a.example")()
		close(got)
	}()
	select {
	case <-got:
		t.Fatal("the same name was locked twice at once")
	case <-time.After(100 * time.Millisecond):
	}
	unlock()
	select {
	case <-got:
	case <-time.After(5 * time.Second):
		t.Fatal("the waiter never got the lock")
	}
	namedLocksMu.Lock()
	n := len(namedLocks)
	namedLocksMu.Unlock()
	if n != 0 {
		t.Errorf("%d lock entries left after every holder released", n)
	}
}
