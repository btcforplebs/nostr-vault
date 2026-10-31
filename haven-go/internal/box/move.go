package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// POST /api/box/move {path}: move the vault (databases, Blossom, relay
// lists) to another disk, e.g. a USB drive mounted under NV_MOVE_ROOT. The
// box's own files (device key, state) stay in NV_DATA_DIR, so the box keeps
// its identity and approval. The engine is stopped for the copy and started
// on the new place after it; on any failure it starts again on the old one.

// MoveState is the current or last move, shown in status.
type MoveState struct {
	From     string `json:"from"`
	To       string `json:"to"`
	Phase    string `json:"phase"` // stopping, copying, verifying, switching, starting, done, failed
	Copied   uint64 `json:"copiedBytes"`
	Total    uint64 `json:"totalBytes"`
	Error    string `json:"error,omitempty"`
	Started  int64  `json:"startedAt"`
	Finished int64  `json:"finishedAt,omitempty"`
}

// EngineControl is what a move needs from the engine.
type EngineControl interface {
	Stop()
	Start(ctx context.Context, vaultDir string) error
	VaultDir() string
}

// Mover runs one move at a time.
type Mover struct {
	Root     string // NV_MOVE_ROOT
	BoxDir   string // state.json lives here
	Engine   EngineControl
	Ctx      context.Context // the box's lifetime, for restarting the engine
	FreeOf   func(path string) (uint64, error)
	Headroom uint64 // free space kept on the target beyond the vault's size

	mu    sync.Mutex
	state *MoveState
	busy  bool
}

// State is a copy of the current or last move, or nil.
func (m *Mover) State() *MoveState {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state == nil {
		return nil
	}
	s := *m.state
	return &s
}

// ErrMoveBusy is returned while a move runs.
var ErrMoveBusy = errors.New("a move is already running")

// Validate checks a requested target without touching anything.
func (m *Mover) Validate(target, from string) (string, error) {
	if target == "" || !filepath.IsAbs(target) {
		return "", errors.New("path must be an absolute path")
	}
	target = filepath.Clean(target)
	root := filepath.Clean(m.Root)
	if !within(target, root) || target == root {
		return "", fmt.Errorf("path must be inside %s (where the box's disks are mounted)", root)
	}
	if resolved, err := filepath.EvalSymlinks(filepath.Dir(target)); err != nil {
		return "", fmt.Errorf("parent of %s does not exist", target)
	} else if rr, _ := filepath.EvalSymlinks(root); !within(resolved, rr) {
		return "", fmt.Errorf("path must be inside %s", root)
	}
	if target == from || within(target, from) || within(from, target) {
		return "", errors.New("path overlaps the vault's current place")
	}
	if st, err := os.Lstat(target); err == nil {
		if !st.IsDir() {
			return "", errors.New("path exists and is not a folder")
		}
		entries, err := os.ReadDir(target)
		if err != nil {
			return "", fmt.Errorf("cannot read %s: %v", target, err)
		}
		if len(entries) > 0 {
			return "", errors.New("path must be an empty or new folder")
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	return target, nil
}

// Begin validates and starts a move in the background.
func (m *Mover) Begin(target string) (*MoveState, error) {
	m.mu.Lock()
	if m.busy {
		m.mu.Unlock()
		return nil, ErrMoveBusy
	}
	from := m.Engine.VaultDir()
	to, err := m.Validate(target, from)
	if err != nil {
		m.mu.Unlock()
		return nil, err
	}
	size, err := treeSize(from, onDisk)
	if err != nil {
		m.mu.Unlock()
		return nil, fmt.Errorf("measuring the vault: %v", err)
	}
	free, err := m.FreeOf(filepath.Dir(to))
	if err != nil {
		m.mu.Unlock()
		return nil, fmt.Errorf("checking free space: %v", err)
	}
	if free < size+m.Headroom {
		m.mu.Unlock()
		return nil, fmt.Errorf("not enough space: the vault is %d bytes, %s has %d free", size, filepath.Dir(to), free)
	}
	m.busy = true
	m.state = &MoveState{From: from, To: to, Phase: "stopping", Total: size, Started: time.Now().Unix()}
	s := *m.state
	m.mu.Unlock()
	go m.run(from, to)
	return &s, nil
}

func (m *Mover) set(f func(*MoveState)) {
	m.mu.Lock()
	f(m.state)
	m.mu.Unlock()
}

func (m *Mover) run(from, to string) {
	fail := func(err error, restartOn string) {
		log.Printf("box: move to %s failed: %v", to, err)
		m.set(func(s *MoveState) { s.Phase, s.Error = "failed", err.Error() })
		if restartOn != "" {
			if serr := m.Engine.Start(m.Ctx, restartOn); serr != nil {
				log.Printf("box: engine restart on %s failed: %v", restartOn, serr)
			}
		}
		m.finish()
	}

	m.Engine.Stop()

	// Stopped, Badger has trimmed its value logs: measure what will be copied.
	if total, err := treeSize(from, func(i fs.FileInfo) uint64 { return uint64(i.Size()) }); err == nil {
		m.set(func(s *MoveState) { s.Total = total })
	}
	m.set(func(s *MoveState) { s.Phase = "copying" })
	createdTarget := false
	if _, err := os.Lstat(to); errors.Is(err, fs.ErrNotExist) {
		// Same disk: a rename is instant and all-or-nothing.
		if err := os.Rename(from, to); err == nil {
			m.set(func(s *MoveState) { s.Copied = s.Total })
			if err := m.switchTo(to); err != nil {
				if rerr := os.Rename(to, from); rerr != nil {
					fail(fmt.Errorf("%v; and putting the vault back failed: %v (it is at %s)", err, rerr, to), "")
					return
				}
				fail(err, from)
				return
			}
			m.startOn(to)
			return
		}
		if err := os.MkdirAll(to, 0o700); err != nil {
			fail(err, from)
			return
		}
		createdTarget = true
	}
	cleanup := func() {
		if createdTarget {
			_ = os.RemoveAll(to)
			return
		}
		entries, _ := os.ReadDir(to)
		for _, e := range entries {
			_ = os.RemoveAll(filepath.Join(to, e.Name()))
		}
	}
	if err := copyTree(from, to, func(n int64) { m.set(func(s *MoveState) { s.Copied += uint64(n) }) }); err != nil {
		cleanup()
		fail(err, from)
		return
	}
	m.set(func(s *MoveState) { s.Phase = "verifying" })
	if err := sameTree(from, to); err != nil {
		cleanup()
		fail(err, from)
		return
	}
	if err := m.switchTo(to); err != nil {
		cleanup()
		fail(err, from)
		return
	}
	// The new copy is now the vault; the old one goes.
	if err := os.RemoveAll(from); err != nil {
		log.Printf("box: moved, but removing the old copy at %s failed: %v", from, err)
	}
	m.startOn(to)
}

func (m *Mover) switchTo(to string) error {
	m.set(func(s *MoveState) { s.Phase = "switching" })
	return SaveVaultDir(m.BoxDir, to)
}

func (m *Mover) startOn(to string) {
	m.set(func(s *MoveState) { s.Phase = "starting" })
	if err := m.Engine.Start(m.Ctx, to); err != nil {
		m.set(func(s *MoveState) { s.Phase, s.Error = "failed", "moved, but the vault did not start: "+err.Error() })
		m.finish()
		return
	}
	m.set(func(s *MoveState) { s.Phase = "done" })
	m.finish()
}

func (m *Mover) finish() {
	m.mu.Lock()
	m.state.Finished = time.Now().Unix()
	m.busy = false
	m.mu.Unlock()
}

type boxState struct {
	VaultDir string `json:"vaultDir"`
}

// LoadVaultDir is where the vault lives: state.json's vaultDir if a move
// set one, else def.
func LoadVaultDir(boxDir, def string) string {
	b, err := os.ReadFile(filepath.Join(boxDir, "state.json"))
	if err != nil {
		return def
	}
	var s boxState
	if json.Unmarshal(b, &s) != nil || s.VaultDir == "" || !filepath.IsAbs(s.VaultDir) {
		return def
	}
	return filepath.Clean(s.VaultDir)
}

// SaveVaultDir records the vault's place atomically.
func SaveVaultDir(boxDir, dir string) error {
	if err := os.MkdirAll(boxDir, 0o700); err != nil {
		return err
	}
	b, _ := json.Marshal(boxState{VaultDir: dir})
	tmp := filepath.Join(boxDir, ".state.json.tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(boxDir, "state.json"))
}

func treeSize(dir string, size func(fs.FileInfo) uint64) (uint64, error) {
	var n uint64
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			n += size(info)
		}
		return nil
	})
	return n, err
}

// copyTree copies regular files and folders. Anything else (symlinks,
// devices) is refused: a vault has none, and following one could copy from
// outside it.
func copyTree(from, to string, progress func(int64)) error {
	return filepath.WalkDir(from, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(from, p)
		if err != nil {
			return err
		}
		dst := filepath.Join(to, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			if rel == "." {
				return nil
			}
			return os.MkdirAll(dst, info.Mode().Perm()|0o700)
		case info.Mode().IsRegular():
			return copyFile(p, dst, info.Mode().Perm(), progress)
		default:
			return fmt.Errorf("%s is not a regular file or folder", strings.TrimPrefix(p, from))
		}
	})
}

func copyFile(src, dst string, perm fs.FileMode, progress func(int64)) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return err
	}
	buf := make([]byte, 1<<20)
	for {
		n, rerr := in.Read(buf)
		if n > 0 {
			if _, werr := out.Write(buf[:n]); werr != nil {
				out.Close()
				return werr
			}
			progress(int64(n))
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			out.Close()
			return rerr
		}
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// sameTree checks every regular file of a is in b with the same size.
func sameTree(a, b string) error {
	return filepath.WalkDir(a, func(p string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		rel, _ := filepath.Rel(a, p)
		ia, err := d.Info()
		if err != nil {
			return err
		}
		ib, err := os.Stat(filepath.Join(b, rel))
		if err != nil {
			return fmt.Errorf("copy is missing %s", rel)
		}
		if ia.Size() != ib.Size() {
			return fmt.Errorf("copy of %s is %d bytes, not %d", rel, ib.Size(), ia.Size())
		}
		return nil
	})
}
