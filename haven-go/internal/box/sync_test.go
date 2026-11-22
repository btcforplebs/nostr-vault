package box

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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
	mu      sync.Mutex
	tokens  map[string]bool
	lastErr map[string]string
	busy    bool
	synced  []string
	firsts  []string
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
		d := CopyDevice{Peer: p, Token: f.tokens[p]}
		if e := f.lastErr[p]; e != "" {
			d.Last = &CopyRun{Kind: "sync", Error: e}
		}
		st.Devices = append(st.Devices, d)
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
	if rep, _ := s.Report(context.Background(), false); len(rep.Devices) != 0 {
		t.Fatalf("an added account sees the owner's devices: %+v", rep.Devices)
	}
	rep, _ := s.Report(context.Background(), true)
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

// Tron #2385 M1: a first copy makes that vault zip its whole vault, so it
// is refused while the box holds a working token, and allowed again only
// once the vault refuses that token.
func TestSyncerFirstCopyRefusedWithToken(t *testing.T) {
	dial := &fakeDialer{}
	eng := &fakeCopyEngine{tokens: map[string]bool{"npub1mac": true}, lastErr: map[string]string{}}
	s := &Syncer{Devices: func() ([]string, error) { return []string{"npub1mac"}, nil }, Dial: dial, Engine: eng}
	if err := s.First(context.Background(), "npub1mac"); !errors.Is(err, ErrHasCopy) {
		t.Fatalf("with a token: %v, want ErrHasCopy", err)
	}
	if len(dial.signed) != 0 || len(dial.dialed) != 0 || len(eng.firsts) != 0 {
		t.Fatalf("reached the vault anyway: %v %v %v", dial.dialed, dial.signed, eng.firsts)
	}
	eng.lastErr["npub1mac"] = "network"
	if err := s.First(context.Background(), "npub1mac"); !errors.Is(err, ErrHasCopy) {
		t.Fatalf("token kept after a network error: %v, want ErrHasCopy", err)
	}
	eng.lastErr["npub1mac"] = "auth_refused"
	if err := s.First(context.Background(), "npub1mac"); err != nil {
		t.Fatalf("token refused by the vault: %v, want a new first copy", err)
	}
	if len(eng.firsts) != 1 {
		t.Fatalf("firsts %v", eng.firsts)
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

// Tron #2385 L1: the control socket lives in its own run dir, 0700, never
// under the data dir unless no run dir can be made, and never through a link.
func TestPrepareControlDir(t *testing.T) {
	root := t.TempDir()
	c := Config{DataDir: filepath.Join(root, "data"), RunDir: filepath.Join(root, "run")}
	if err := PrepareControlDir(&c); err != nil {
		t.Fatal(err)
	}
	if c.EngineControlSocket() != filepath.Join(root, "run", "engine.sock") {
		t.Fatalf("socket %s, want it in the run dir", c.EngineControlSocket())
	}
	if fi, err := os.Stat(c.RunDir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("run dir: %v %v", fi, err)
	}
	link := Config{DataDir: c.DataDir, RunDir: filepath.Join(root, "link")}
	os.Symlink(filepath.Join(root, "run"), link.RunDir)
	if err := PrepareControlDir(&link); err == nil {
		t.Fatal("took a link as the run dir")
	}
	if link.RunDir != filepath.Join(root, "link") {
		t.Fatal("a set NV_BOX_RUN_DIR fell back to the data dir")
	}
}

func TestSyncNowThrottle(t *testing.T) {
	s := &Syncer{NowEvery: time.Minute}
	t0 := time.Unix(1000, 0)
	if w := s.allowNow("npub1mac", t0); w != 0 {
		t.Fatalf("first ask waited %v", w)
	}
	if w := s.allowNow("npub1mac", t0.Add(10*time.Second)); w != 50*time.Second {
		t.Fatalf("second ask within a minute: wait %v, want 50s", w)
	}
	if w := s.allowNow("npub1phone", t0.Add(10*time.Second)); w != 0 {
		t.Fatalf("another device waited %v", w)
	}
	if w := s.allowNow("", t0.Add(20*time.Second)); w != 0 {
		t.Fatalf("all waited %v", w)
	}
	if w := s.allowNow("npub1laptop", t0.Add(30*time.Second)); w != 50*time.Second {
		t.Fatalf("a device right after all: wait %v, want 50s", w)
	}
	if w := s.allowNow("npub1mac", t0.Add(81*time.Second)); w != 0 {
		t.Fatalf("after the window: wait %v", w)
	}
}
