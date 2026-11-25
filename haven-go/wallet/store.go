package wallet

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
)

// Store keeps the wallet State durably. Save must not return until the state
// is on disk (or in the platform secret store): the wallet calls the mint only
// after Save returns nil.
type Store interface {
	Load() (*State, error) // a missing store is an empty State, not an error
	Save(*State) error
}

// FileStore keeps the State as one JSON file, written with write-temp, fsync,
// rename, fsync-dir, mode 0600. It is for the Mac/box engine and tests; the
// phone apps bring their own Store through E3.
type FileStore struct {
	Path string
}

func (f FileStore) Load() (*State, error) {
	b, err := os.ReadFile(f.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return newState(), nil
	}
	if err != nil {
		return nil, err
	}
	return decodeState(b)
}

func (f FileStore) Save(s *State) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	dir := filepath.Dir(f.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".wallet-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			tmp.Close()
			os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, f.Path); err != nil {
		return err
	}
	ok = true
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// MemStore keeps the State in memory as JSON (tests, and apps that hand the
// JSON to their own secret store).
type MemStore struct {
	mu   sync.Mutex
	data []byte
	// FailSave, when set, makes Save fail (tests).
	FailSave error
}

func (m *MemStore) Load() (*State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.data == nil {
		return newState(), nil
	}
	return decodeState(m.data)
}

func (m *MemStore) Save(s *State) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailSave != nil {
		return m.FailSave
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	m.data = b
	return nil
}

func decodeState(b []byte) (*State, error) {
	s := newState()
	if err := json.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("wallet state unreadable: %w", err)
	}
	if s.Version > StateVersion {
		return nil, fmt.Errorf("wallet state version %d is newer than this app (%d)", s.Version, StateVersion)
	}
	if s.Mints == nil {
		s.Mints = map[string]*MintState{}
	}
	return s, nil
}
