package box

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A stand-in engine: appends its pid and working dir to a log, then sleeps
// (or exits at once when the dir has a "crash" file).
func fakeEngineBin(t *testing.T) (bin, logPath string) {
	dir := t.TempDir()
	logPath = filepath.Join(dir, "runs.log")
	bin = filepath.Join(dir, "engine.sh")
	script := "#!/bin/sh\necho \"$$ $(pwd) $RELAY_PORT\" >> " + logPath + "\n[ -f crash ] && exit 1\nexec sleep 60\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, logPath
}

func runs(logPath string) []string {
	b, _ := os.ReadFile(logPath)
	return strings.Fields(strings.ReplaceAll(string(b), "\n", " |"))
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestEngineStartStopAndPrepare(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	vault := t.TempDir()
	prepared := ""
	e := &Engine{
		Bin:      bin,
		Env:      func(string) []string { return []string{"RELAY_PORT=4321", "PATH=/bin:/usr/bin"} },
		Prepare:  func(d string) error { prepared = d; return nil },
		StopWait: 2 * time.Second,
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, vault); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return len(runs(logPath)) >= 3 })
	if prepared != vault {
		t.Fatalf("Prepare got %q", prepared)
	}
	r := runs(logPath)
	if real, _ := filepath.EvalSymlinks(vault); r[1] != real && r[1] != vault || r[2] != "4321" {
		t.Fatalf("engine ran with %v", r)
	}
	st := e.State()
	if !st.Running || st.Pid == 0 {
		t.Fatalf("state %+v", st)
	}
	if err := e.Start(ctx, vault); err == nil {
		t.Fatal("double start accepted")
	}
	e.Stop()
	if e.State().Running {
		t.Fatal("still running after Stop")
	}
	time.Sleep(1200 * time.Millisecond) // past the first restart backoff
	if n := strings.Count(strings.Join(runs(logPath), " "), "|"); n != 1 {
		t.Fatalf("engine restarted after Stop: %v", runs(logPath))
	}
}

func TestEngineRestartsAfterCrash(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	vault := t.TempDir()
	os.WriteFile(filepath.Join(vault, "crash"), nil, 0o600)
	e := &Engine{Bin: bin, Env: func(string) []string { return []string{"PATH=/bin:/usr/bin"} }, StopWait: time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, vault); err != nil {
		t.Fatal(err)
	}
	// First run crashes; the restart (after 1s) finds no crash file and stays up.
	time.Sleep(200 * time.Millisecond)
	os.Remove(filepath.Join(vault, "crash"))
	waitFor(t, func() bool { return strings.Count(strings.Join(runs(logPath), " "), "|") >= 2 })
	waitFor(t, func() bool { return e.State().Running })
	if e.State().Restarts != 1 {
		t.Fatalf("restarts %d", e.State().Restarts)
	}
	e.Stop()
}

func TestEngineStopsWithContext(t *testing.T) {
	bin, _ := fakeEngineBin(t)
	e := &Engine{Bin: bin, Env: func(string) []string { return []string{"PATH=/bin:/usr/bin"} }, StopWait: time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	if err := e.Start(ctx, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return e.State().Running })
	cancel()
	waitFor(t, func() bool { return !e.State().Running })
}

// A Stop and Start while an old watch loop waits out its backoff must not
// leave two engines on one vault.
func TestEngineRestartDuringBackoffRunsOneEngine(t *testing.T) {
	bin, logPath := fakeEngineBin(t)
	vault := t.TempDir()
	os.WriteFile(filepath.Join(vault, "crash"), nil, 0o600)
	e := &Engine{Bin: bin, Env: func(string) []string { return []string{"PATH=/bin:/usr/bin"} }, StopWait: time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := e.Start(ctx, vault); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return strings.Count(strings.Join(runs(logPath), " "), "|") >= 1 })
	time.Sleep(100 * time.Millisecond) // the crash is seen; the old loop is in its 1s backoff
	e.Stop()
	os.Remove(filepath.Join(vault, "crash"))
	if err := e.Start(ctx, vault); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1500 * time.Millisecond) // past the old loop's backoff
	if n := strings.Count(strings.Join(runs(logPath), " "), "|"); n != 2 {
		t.Fatalf("%d engine starts, want 2: %v", n, runs(logPath))
	}
	e.Stop()
}
