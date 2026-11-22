package box

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func starts(logPath string) int { return strings.Count(strings.Join(runs(logPath), " "), "|") }

// Reload: a new child at once, Prepare run again (so the account lists are
// rewritten), not counted as a crash restart.
func TestEngineReloadRespawnsAndPrepares(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	var prepared atomic.Int32
	e := &Engine{
		Bin:      bin,
		Env:      func(string) []string { return []string{"PATH=/bin:/usr/bin"} },
		Prepare:  func(string) error { prepared.Add(1); return nil },
		StopWait: 2 * time.Second,
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return e.State().Running && starts(logPath) == 1 })
	pid := e.State().Pid
	t0 := time.Now()
	if !e.Reload() {
		t.Fatal("Reload of a running engine reported false")
	}
	waitFor(t, func() bool { s := e.State(); return s.Running && s.Pid != pid })
	if d := time.Since(t0); d > 900*time.Millisecond {
		t.Fatalf("reload took %s: it waited out the crash backoff", d)
	}
	if n := prepared.Load(); n != 2 {
		t.Fatalf("Prepare ran %d times, want 2", n)
	}
	if r := e.State().Restarts; r != 0 {
		t.Fatalf("a reload counted as %d crash restarts", r)
	}
	waitFor(t, func() bool { return starts(logPath) == 2 })
	e.Stop()
}

// A stopped engine (a Move in progress) stays stopped: Reload never starts
// one, so it cannot reopen the vault a Move is copying.
func TestEngineReloadLeavesAStoppedEngineStopped(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	e := &Engine{Bin: bin, Env: func(string) []string { return []string{"PATH=/bin:/usr/bin"} }, StopWait: time.Second}
	if e.Reload() {
		t.Fatal("Reload of a never-started engine reported true")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return e.State().Running && starts(logPath) == 1 })
	e.Stop()
	if e.Reload() {
		t.Fatal("Reload of a stopped engine reported true")
	}
	time.Sleep(1200 * time.Millisecond)
	if e.State().Running || starts(logPath) != 1 {
		t.Fatalf("a stopped engine was started by Reload: %v", runs(logPath))
	}
}

// Tron #2374: a watch loop that saw a reload, then lost the CPU to a Move's
// Stop, must not start a child after Stop returned. spawn re-checks wanted
// and the generation under its own lock; a stale or stopped caller is refused.
func TestEngineSpawnRefusesAStoppedOrOlderGeneration(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	e := &Engine{Bin: bin, Env: func(string) []string { return []string{"PATH=/bin:/usr/bin"} }, StopWait: time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return e.State().Running && starts(logPath) == 1 })
	e.mu.Lock()
	gen1 := e.gen
	e.mu.Unlock()

	e.Stop() // the Move
	if err := e.spawn(gen1); err != errNotWanted {
		t.Fatalf("spawn after Stop: %v, want errNotWanted", err)
	}
	if e.State().Running || starts(logPath) != 1 {
		t.Fatalf("a child started after Stop returned: %v", runs(logPath))
	}

	if err := e.Start(ctx, t.TempDir()); err != nil { // the Move's restart
		t.Fatal(err)
	}
	waitFor(t, func() bool { return e.State().Running && starts(logPath) == 2 })
	if err := e.spawn(gen1); err != errNotWanted {
		t.Fatalf("spawn from an older watch loop: %v, want errNotWanted", err)
	}
	if starts(logPath) != 2 {
		t.Fatalf("an older watch loop started a second child: %v", runs(logPath))
	}
	e.Stop()
}
