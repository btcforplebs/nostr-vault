package main

import (
	"context"
	"net"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

func TestBlastBackoffDoublesToSixHours(t *testing.T) {
	want := []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute}
	for i, w := range want {
		if got := blastBackoff(i + 1); got != w {
			t.Fatalf("backoff after try %d = %v, want %v", i+1, got, w)
		}
	}
	if got := blastBackoff(100); got != blastBackoffMax {
		t.Fatalf("backoff after 100 tries = %v, want %v", got, blastBackoffMax)
	}
}

// blastTestSetup points the blastr at urls with a fresh pool and owner key.
func blastTestSetup(t *testing.T, urls ...string) (context.Context, string) {
	t.Chdir(t.TempDir())
	prevConfig, prevPool := config, pool
	t.Cleanup(func() { config, pool = prevConfig, prevPool })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	pool = nostr.NewSimplePool(ctx)
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	config.WhitelistedPubKeys = map[string]struct{}{pk: {}}
	config.BlastrRelays = urls
	config.BlastrTimeoutSeconds = 1
	return ctx, sk
}

func deadRelayURL() string {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	defer l.Close()
	return "ws://" + l.Addr().String()
}

// A queued note is not retried before its backoff runs out, and each failed
// try pushes the next one further out. The old loop tried every minute.
func TestQueuedBlastWaitsOutItsBackoff(t *testing.T) {
	ctx, sk := blastTestSetup(t, deadRelayURL())
	clock := time.Now()
	blastClock = func() time.Time { return clock }
	t.Cleanup(func() { blastClock = time.Now })

	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "offline"}
	ev.Sign(sk)
	q := openBlastQueue(blastPendingFile)
	blastOrKeep(ctx, q, &ev)
	if s := q.snapshot(); len(s) != 1 || s[0].Attempts != 1 {
		t.Fatalf("queue after first blast: %+v", s)
	}

	clock = clock.Add(30 * time.Second)
	retryPendingOnce(ctx, q)
	if a := q.snapshot()[0].Attempts; a != 1 {
		t.Fatalf("retried before the 1 min backoff ran out (attempts %d)", a)
	}

	clock = clock.Add(time.Minute)
	retryPendingOnce(ctx, q)
	s := q.snapshot()
	if s[0].Attempts != 2 {
		t.Fatalf("attempts after a due retry = %d, want 2", s[0].Attempts)
	}
	if want := clock.Add(2 * time.Minute).Unix(); s[0].NextAt != want {
		t.Fatalf("next try at %d, want %d (2 min out)", s[0].NextAt, want)
	}

	// The backoff survives a restart.
	if r := openBlastQueue(blastPendingFile).snapshot(); r[0].Attempts != 2 || r[0].NextAt != s[0].NextAt {
		t.Fatalf("backoff lost on restart: %+v", r[0])
	}
}

// rejectingRelay answers OK false to every note and counts the tries.
func rejectingRelay(t *testing.T) (string, *atomic.Int32) {
	var tries atomic.Int32
	r := khatru.NewRelay()
	r.RejectEvent = append(r.RejectEvent, func(context.Context, *nostr.Event) (bool, string) {
		tries.Add(1)
		return true, "blocked: not on this relay"
	})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http"), &tries
}

// A relay that refuses a note is asked once, and a note every relay refused
// is not kept for later.
func TestRejectedBlastIsNotRetried(t *testing.T) {
	url, tries := rejectingRelay(t)
	ctx, sk := blastTestSetup(t, url)
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "refused"}
	ev.Sign(sk)
	q := openBlastQueue(blastPendingFile)
	blastOrKeep(ctx, q, &ev)
	if n := tries.Load(); n != 1 {
		t.Fatalf("relay asked %d times, want 1", n)
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatalf("refused note queued: %d", len(s))
	}
}

// A queued note that comes back refused (and no relay is down) is dropped.
func TestQueuedBlastRefusedIsDropped(t *testing.T) {
	url, tries := rejectingRelay(t)
	ctx, sk := blastTestSetup(t, url)
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "refused later"}
	ev.Sign(sk)
	q := openBlastQueue(blastPendingFile)
	q.items = []pendingBlast{{Event: ev, QueuedAt: time.Now().Unix()}}
	retryPendingOnce(ctx, q)
	if n := tries.Load(); n != 1 {
		t.Fatalf("relay asked %d times, want 1", n)
	}
	if s := q.snapshot(); len(s) != 0 {
		t.Fatal("refused note kept in the queue")
	}
}

// One relay down and one refusing: the note stays queued for the down one.
func TestBlastKeptWhenOneRelayIsDown(t *testing.T) {
	url, _ := rejectingRelay(t)
	ctx, sk := blastTestSetup(t, url, deadRelayURL())
	ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "half"}
	ev.Sign(sk)
	q := openBlastQueue(blastPendingFile)
	blastOrKeep(ctx, q, &ev)
	if s := q.snapshot(); len(s) != 1 {
		t.Fatalf("queue = %d, want the note kept for the down relay", len(s))
	}
}

func TestRateLimitIsNotARejection(t *testing.T) {
	if isRejection(errorString("msg: rate-limited: slow down")) {
		t.Fatal("rate limit counted as a final rejection")
	}
	if !isRejection(errorString("msg: blocked: no")) {
		t.Fatal("blocked not counted as a rejection")
	}
	if isRejection(context.DeadlineExceeded) {
		t.Fatal("timeout counted as a rejection")
	}
}

type errorString string

func (e errorString) Error() string { return string(e) }
