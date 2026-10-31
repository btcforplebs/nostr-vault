package box

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeEngine struct {
	mu    sync.Mutex
	dir   string
	log   []string
	start func(dir string) error
}

func (f *fakeEngine) Stop() { f.mu.Lock(); f.log = append(f.log, "stop"); f.mu.Unlock() }
func (f *fakeEngine) Start(_ context.Context, dir string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log = append(f.log, "start "+dir)
	if f.start != nil {
		if err := f.start(dir); err != nil {
			return err
		}
	}
	f.dir = dir
	return nil
}
func (f *fakeEngine) VaultDir() string { f.mu.Lock(); defer f.mu.Unlock(); return f.dir }

func makeVault(t *testing.T, dir string) {
	t.Helper()
	files := map[string]string{
		"data/outbox/000001.vlog":             strings.Repeat("x", 5000),
		"db/inbox/000001.vlog":                strings.Repeat("y", 5000),
		"blossom/" + strings.Repeat("ab", 32): "blob",
		"relays_import.json":                  "[]",
	}
	for p, c := range files {
		full := filepath.Join(dir, p)
		os.MkdirAll(filepath.Dir(full), 0o700)
		if err := os.WriteFile(full, []byte(c), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func newMover(t *testing.T) (*Mover, *fakeEngine, string, string) {
	base := t.TempDir()
	vault := filepath.Join(base, "data", "vault")
	root := filepath.Join(base, "mnt")
	os.MkdirAll(filepath.Join(root, "usb"), 0o755)
	makeVault(t, vault)
	eng := &fakeEngine{dir: vault}
	m := &Mover{
		Root: root, BoxDir: filepath.Join(base, "data", "box"), Engine: eng, Ctx: context.Background(),
		FreeOf: func(string) (uint64, error) { return 1 << 30, nil },
	}
	return m, eng, vault, root
}

func waitMove(t *testing.T, m *Mover) *MoveState {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if s := m.State(); s != nil && s.Finished != 0 {
			return s
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("move did not finish")
	return nil
}

func TestMoveIntoEmptyFolderCopies(t *testing.T) {
	m, eng, vault, root := newMover(t)
	target := filepath.Join(root, "usb") // exists, empty: forces the copy path
	if _, err := m.Begin(target); err != nil {
		t.Fatal(err)
	}
	s := waitMove(t, m)
	if s.Phase != "done" || s.Copied != s.Total || s.Total == 0 {
		t.Fatalf("state %+v", s)
	}
	if b, err := os.ReadFile(filepath.Join(target, "blossom", strings.Repeat("ab", 32))); err != nil || string(b) != "blob" {
		t.Fatalf("blob not copied: %v", err)
	}
	if _, err := os.Stat(vault); !os.IsNotExist(err) {
		t.Fatalf("old vault still there: %v", err)
	}
	if got := LoadVaultDir(m.BoxDir, "/default"); got != target {
		t.Fatalf("state.json says %q", got)
	}
	if strings.Join(eng.log, ",") != "stop,start "+target {
		t.Fatalf("engine calls %v", eng.log)
	}
}

func TestMoveToNewFolderRenames(t *testing.T) {
	m, _, vault, root := newMover(t)
	target := filepath.Join(root, "usb", "vault")
	if _, err := m.Begin(target); err != nil {
		t.Fatal(err)
	}
	if s := waitMove(t, m); s.Phase != "done" {
		t.Fatalf("state %+v", s)
	}
	if _, err := os.Stat(filepath.Join(target, "relays_import.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(vault); !os.IsNotExist(err) {
		t.Fatal("old vault still there")
	}
}

func TestMoveRefusals(t *testing.T) {
	m, eng, vault, root := newMover(t)
	os.WriteFile(filepath.Join(root, "usb", "keep.txt"), []byte("mine"), 0o600)
	os.WriteFile(filepath.Join(root, "file"), []byte("x"), 0o600)
	for _, p := range []string{
		"", "relative/path", root, "/etc/vault", filepath.Join(root, "..", "escape"),
		filepath.Join(root, "usb"),           // not empty
		filepath.Join(root, "file"),          // not a folder
		filepath.Join(root, "nope", "vault"), // parent missing
		filepath.Join(vault, "inside"),
	} {
		if _, err := m.Begin(p); err == nil {
			t.Errorf("move to %q accepted", p)
		}
	}
	if len(eng.log) != 0 {
		t.Fatalf("a refused move touched the engine: %v", eng.log)
	}
	// A symlink inside the root pointing out of it is refused too.
	out := t.TempDir()
	os.Symlink(out, filepath.Join(root, "link"))
	if _, err := m.Begin(filepath.Join(root, "link", "vault")); err == nil {
		t.Error("move through a symlink out of the root accepted")
	}
}

func TestMoveNeedsSpace(t *testing.T) {
	m, _, _, root := newMover(t)
	m.FreeOf = func(string) (uint64, error) { return 10, nil }
	if _, err := m.Begin(filepath.Join(root, "usb", "v")); err == nil || !strings.Contains(err.Error(), "space") {
		t.Fatalf("want space error, got %v", err)
	}
}

func TestMoveFailureRestartsOnTheOldPlace(t *testing.T) {
	m, eng, vault, root := newMover(t)
	// A symlink in the vault makes the copy fail part way.
	os.Symlink("/etc/passwd", filepath.Join(vault, "zz-link"))
	target := filepath.Join(root, "usb")
	if _, err := m.Begin(target); err != nil {
		t.Fatal(err)
	}
	s := waitMove(t, m)
	if s.Phase != "failed" || s.Error == "" {
		t.Fatalf("state %+v", s)
	}
	if eng.VaultDir() != vault || strings.Join(eng.log, ",") != "stop,start "+vault {
		t.Fatalf("engine %v on %s", eng.log, eng.VaultDir())
	}
	if entries, _ := os.ReadDir(target); len(entries) != 0 {
		t.Fatalf("partial copy left behind: %v", entries)
	}
	if _, err := os.Stat(filepath.Join(vault, "relays_import.json")); err != nil {
		t.Fatal("old vault damaged")
	}
	if got := LoadVaultDir(m.BoxDir, vault); got != vault {
		t.Fatalf("state.json moved to %q", got)
	}
}

func TestMoveOneAtATime(t *testing.T) {
	m, eng, _, root := newMover(t)
	block := make(chan struct{})
	eng.start = func(string) error { <-block; return nil }
	if _, err := m.Begin(filepath.Join(root, "usb", "a")); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Begin(filepath.Join(root, "usb", "b")); err != ErrMoveBusy {
		t.Fatalf("second move: %v", err)
	}
	close(block)
	waitMove(t, m)
}
