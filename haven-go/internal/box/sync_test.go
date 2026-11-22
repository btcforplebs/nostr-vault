package box

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type fakeDialer struct {
	mu     sync.Mutex
	down   map[string]bool
	dialed []string
	signed []string
}

func (f *fakeDialer) Dial(_ context.Context, npub string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.dialed = append(f.dialed, npub)
	if f.down[npub] {
		return "", errors.New("nv-mesh: could not reach it over the mesh (-1)")
	}
	return "http://127.0.0.1:4242/tok", nil
}

func (f *fakeDialer) SignCopyStart(_ context.Context, npub, _ string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.signed = append(f.signed, npub)
	return "proof", nil
}

type fakeCopyEngine struct {
	mu     sync.Mutex
	tokens map[string]bool
	busy   bool
	synced []string
	firsts []string
}

func (f *fakeCopyEngine) First(_ context.Context, peer, _, auth string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.busy {
		return ErrCopyBusy
	}
	f.firsts = append(f.firsts, peer+" "+auth)
	return nil
}

func (f *fakeCopyEngine) Sync(_ context.Context, peer, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.synced = append(f.synced, peer)
	return nil
}

func (f *fakeCopyEngine) State(_ context.Context, peers []string) (CopyState, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	st := CopyState{Busy: f.busy, Devices: []CopyDevice{}}
	for _, p := range peers {
		st.Devices = append(st.Devices, CopyDevice{Peer: p, Token: f.tokens[p]})
	}
	return st, nil
}

func TestSyncerRoundCatchesUpOnlyWithTokens(t *testing.T) {
	dial := &fakeDialer{down: map[string]bool{"npub1down": true}}
	eng := &fakeCopyEngine{tokens: map[string]bool{"npub1mac": true, "npub1down": true}}
	s := &Syncer{
		Devices: func() ([]string, error) { return []string{"npub1mac", "npub1phone", "npub1down"}, nil },
		Dial:    dial, Engine: eng, Poll: time.Millisecond,
	}
	s.Round(context.Background(), "")
	if len(eng.synced) != 1 || eng.synced[0] != "npub1mac" {
		t.Fatalf("synced %v, want only the reachable device with a token", eng.synced)
	}
	if len(eng.firsts) != 0 || len(dial.signed) != 0 {
		t.Fatalf("a round started a first copy or asked for a proof: %v %v", eng.firsts, dial.signed)
	}
	rep, _ := s.Report(context.Background())
	for _, d := range rep.Devices {
		switch d.Peer {
		case "npub1phone":
			if d.Needs != "first_copy" {
				t.Fatalf("phone: %+v", d)
			}
		case "npub1down":
			if d.Reach == "" {
				t.Fatalf("down device has no reach error: %+v", d)
			}
		}
	}
	eng.synced = nil
	s.Round(context.Background(), "npub1mac")
	if len(eng.synced) != 1 {
		t.Fatalf("one-device round synced %v", eng.synced)
	}
}

func TestSyncerFirstCopy(t *testing.T) {
	dial := &fakeDialer{}
	eng := &fakeCopyEngine{}
	s := &Syncer{Devices: func() ([]string, error) { return []string{"npub1mac"}, nil }, Dial: dial, Engine: eng}
	if err := s.First(context.Background(), "npub1stranger"); !errors.Is(err, ErrNotPaired) {
		t.Fatalf("stranger: %v", err)
	}
	if err := s.Now("npub1stranger"); !errors.Is(err, ErrNotPaired) {
		t.Fatalf("sync now, stranger: %v", err)
	}
	eng.busy = true
	if err := s.First(context.Background(), "npub1mac"); !errors.Is(err, ErrCopyBusy) {
		t.Fatalf("busy: %v", err)
	}
	if len(dial.signed) != 0 {
		t.Fatal("asked nv-mesh for a proof while busy")
	}
	eng.busy = false
	if err := s.First(context.Background(), "npub1mac"); err != nil {
		t.Fatal(err)
	}
	if len(eng.firsts) != 1 || eng.firsts[0] != "npub1mac proof" {
		t.Fatalf("first copy started with %v, want nv-mesh's proof", eng.firsts)
	}
}

func TestSyncerNowNeverBlocks(t *testing.T) {
	s := &Syncer{Devices: func() ([]string, error) { return []string{"npub1mac"}, nil }}
	for range 5 {
		if err := s.Now("npub1mac"); err != nil {
			t.Fatal(err)
		}
	}
	if got := <-s.kick; got != "" {
		t.Fatalf("pending kick %q, want all devices after several asks", got)
	}
}
