package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// The blast storm on Logen's .99 Mac (2026-11-12,
// RESEARCH/NV_MAC_RELAY_PROFILE_2026_11_12.md): 38,808 events stored in a
// minute, one blast goroutine each, 185,349 publishes blocked in
// go-nostr Relay.Write, a 2-3 GB heap and the GC on every core.

// stallingRelay takes every note and answers nothing until the test ends,
// like a slow or wedged public relay.
func stallingRelay(t *testing.T) string {
	release := make(chan struct{})
	r := khatru.NewRelay()
	r.RejectEvent = append(r.RejectEvent, func(ctx context.Context, _ *nostr.Event) (bool, string) {
		select {
		case <-release:
		case <-ctx.Done():
		}
		return true, "blocked: stalled"
	})
	srv := httptest.NewServer(r)
	t.Cleanup(func() { close(release); srv.CloseClientConnections(); srv.Close() })
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func signedNotes(t *testing.T, sk string, n int) []*nostr.Event {
	t.Helper()
	out := make([]*nostr.Event, n)
	for i := range out {
		ev := &nostr.Event{Kind: 1, CreatedAt: nostr.Timestamp(1_700_000_000 + i), Content: fmt.Sprintf("note %d", i)}
		ev.Sign(sk)
		out[i] = ev
	}
	return out
}

func heapAndStacks() uint64 {
	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return ms.HeapInuse + ms.StackInuse
}

// A burst of 40,000 stored notes, with every blastr relay stalled, keeps
// the goroutine count and memory bounded: a fixed pool works the notes, and
// what does not fit waits in the blast queue.
func TestBlastBurstStaysBounded(t *testing.T) {
	ctx, sk := blastTestSetup(t, stallingRelay(t), stallingRelay(t))
	config.OwnerPubKey, _ = nostr.GetPublicKey(sk)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	notes := signedNotes(t, sk, 40_000)
	q := openBlastQueue(blastPendingFile)
	send, done := newBlastSender(ctx, q)
	t.Cleanup(func() { cancel(); <-done })

	baseG, baseMem := runtime.NumGoroutine(), heapAndStacks()
	var peak atomic.Int64
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			if g := int64(runtime.NumGoroutine()); g > peak.Load() {
				peak.Store(g)
			}
			select {
			case <-stop:
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
	}()
	for _, ev := range notes {
		send(ev)
	}
	time.Sleep(500 * time.Millisecond)
	close(stop)
	wg.Wait()
	grown := int64(heapAndStacks()) - int64(baseMem)

	if extra := peak.Load() - int64(baseG); extra > 300 {
		t.Errorf("goroutines grew by %d for a 40,000-note burst (want a fixed pool)", extra)
	}
	if grown > 96<<20 {
		t.Errorf("heap+stacks grew by %d MB for a 40,000-note burst", grown>>20)
	}
	t.Logf("burst: +%d goroutines at peak, +%d MB heap+stacks", peak.Load()-int64(baseG), grown>>20)
}

// A note the outbox already holds is not blasted again: a regular note, and
// a replaceable one (khatru hands those to ReplaceEvent, which returns nil
// for a copy it already has, so the chain used to go on to the blast).
func TestOutboxDoesNotBlastADuplicate(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	relay := khatru.NewRelay()
	var mu sync.Mutex
	var blasted []string
	wireOutboxWrites(relay, db, func(ev *nostr.Event) {
		mu.Lock()
		blasted = append(blasted, fmt.Sprintf("%d:%s", ev.Kind, ev.ID[:8]))
		mu.Unlock()
	})
	ctx := context.Background()

	note := &nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "hello"}
	note.Sign(sk)
	profile := &nostr.Event{PubKey: pk, Kind: 0, CreatedAt: nostr.Now(), Content: `{"name":"me"}`}
	profile.Sign(sk)
	list := &nostr.Event{PubKey: pk, Kind: 30023, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"d", "post"}}, Content: "long"}
	list.Sign(sk)

	for round := 0; round < 3; round++ {
		for _, ev := range []*nostr.Event{note, profile, list} {
			copy := *ev // a fresh copy each time, as from the websocket
			if _, err := relay.AddEvent(ctx, &copy); err != nil {
				t.Fatalf("round %d kind %d: %v", round, ev.Kind, err)
			}
		}
	}
	want := []string{"1:" + note.ID[:8], "0:" + profile.ID[:8], "30023:" + list.ID[:8]}
	if fmt.Sprint(blasted) != fmt.Sprint(want) {
		t.Fatalf("blasted %v, want each once %v", blasted, want)
	}
	if !outboxHolds(ctx, profile.ID) || !outboxHolds(ctx, list.ID) {
		t.Fatal("the outbox lost a note it held")
	}
}

// When the pool's queue is full, a note from any of the vault's accounts
// waits in the blast queue: never lost, however long the queue is (Tron's
// review: an untried note dropped at the cap was never published, and the
// client had its OK). On stop, every note still in the pool is kept too.
func TestBlastOverflowKeepsEveryVaultAccountsNotes(t *testing.T) {
	ctx, sk := blastTestSetup(t, stallingRelay(t))
	owner, _ := nostr.GetPublicKey(sk)
	config.OwnerPubKey = owner
	otherSK := nostr.GeneratePrivateKey()
	other, _ := nostr.GetPublicKey(otherSK)
	config.WhitelistedPubKeys[other] = struct{}{}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	q := openBlastQueue(blastPendingFile)
	send, done := newBlastSender(ctx, q)
	t.Cleanup(func() { cancel(); <-done })
	// The owner's backlog fills the blast queue past its cap first.
	ownerNotes := signedNotes(t, sk, blastPendingMax+blastPoolQueue+200)
	otherNotes := signedNotes(t, otherSK, 300)
	for _, ev := range ownerNotes {
		send(ev)
	}
	for _, ev := range otherNotes {
		send(ev)
	}
	q.flush()

	count := func() map[string]int {
		kept := map[string]int{}
		for _, p := range q.snapshot() {
			kept[p.Event.PubKey]++
		}
		return kept
	}
	// Every note is in the pool (queued or being sent) or kept.
	inPool := blastPoolQueue + blastPoolWorkers
	if k := count(); k[owner]+k[other] < len(ownerNotes)+len(otherNotes)-inPool || k[other] == 0 {
		t.Errorf("kept owner %d + other %d of %d notes; at most %d may be in the pool",
			k[owner], k[other], len(ownerNotes)+len(otherNotes), inPool)
	}

	// On stop, every note not yet sent ends up in the blast queue.
	cancel()
	<-done
	q.flush()
	if k := count(); k[owner] != len(ownerNotes) || k[other] != len(otherNotes) {
		t.Errorf("after stop kept owner %d/%d, other %d/%d", k[owner], len(ownerNotes), k[other], len(otherNotes))
	}
}

// The cap still holds for a key that is not one of the vault's accounts
// (say one removed since): such a note is not kept past blastPendingMax.
func TestBlastQueueCapsNotesFromOutsideTheVault(t *testing.T) {
	_, sk := blastTestSetup(t)
	q := openBlastQueue(blastPendingFile)
	for _, ev := range signedNotes(t, sk, blastPendingMax) {
		q.keepUntried(ev)
	}
	stranger := signedNotes(t, nostr.GeneratePrivateKey(), 1)[0]
	q.keepUntried(stranger)
	q.flush()
	if n := len(q.snapshot()); n != blastPendingMax {
		t.Fatalf("queue holds %d, want %d (stranger's note not kept)", n, blastPendingMax)
	}
}
