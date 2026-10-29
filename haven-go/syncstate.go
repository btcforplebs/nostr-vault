package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"path/filepath"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// The sync loops' saved place: their watermarks and the inbox's WoT rejects,
// one small JSON file per loop in the relay's db folder. Without it every
// relay start began again from fixed windows (24 h of inbox, the whole 7-day
// rare-kinds window, 32 days of given zaps) and re-downloaded every event the
// WoT had already turned away, and the Android watchdog restarts the relay
// often.
var (
	inboxSyncStateFile = "db/inbox_sync_state.json"
	feedSyncStateFile  = "db/feed_sync_state.json"
)

type savedReject struct {
	TS     int64  `json:"ts"`
	Pubkey string `json:"pk"`
}

type syncStateFile struct {
	Marks   map[string]int64       `json:"marks"`
	Rejects map[string]savedReject `json:"rejects,omitempty"`
}

// syncState is one loop's saved place. Methods are nil-safe and safe for
// concurrent use.
type syncState struct {
	mu   sync.Mutex
	fs   afero.Fs
	path string
	data syncStateFile
	last []byte // what is on disk, so an unchanged round writes nothing
}

// openSyncState reads file (missing or unreadable: start empty). The path is
// made absolute now, so a round that ends after an account switch still
// writes into its own account's folder.
func openSyncState(appfs afero.Fs, file string) *syncState {
	path, err := filepath.Abs(file)
	if err != nil {
		path = file
	}
	s := &syncState{fs: appfs, path: path}
	if raw, err := afero.ReadFile(appfs, path); err == nil {
		if err := json.Unmarshal(raw, &s.data); err != nil {
			slog.Warn("⚠️ unreadable sync state, starting fresh", "path", path, "error", err)
			s.data = syncStateFile{}
		} else {
			s.last = raw
		}
	}
	if s.data.Marks == nil {
		s.data.Marks = map[string]int64{}
	}
	return s
}

// mark returns the saved watermark key, or def when none is saved. A saved
// one is held inside [floor, now]: never older than the window the loop
// covers anyway, never in the future (a clock that jumped back).
func (s *syncState) mark(key string, def, floor int64) int64 {
	if s == nil {
		return def
	}
	s.mu.Lock()
	v, ok := s.data.Marks[key]
	s.mu.Unlock()
	if !ok || v <= 0 {
		return def
	}
	if now := time.Now().Unix(); v > now {
		v = now
	}
	return max(v, floor)
}

func (s *syncState) setMark(key string, v int64) {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.data.Marks[key] = v
	s.mu.Unlock()
}

// keepRejects copies the reject cache into the state for the next save.
func (s *syncState) keepRejects(t *tempRejects) {
	if s == nil || t == nil {
		return
	}
	out := map[string]savedReject{}
	t.m.Range(func(k, v any) bool {
		e := v.(rejectEntry)
		out[k.(string)] = savedReject{TS: int64(e.ts), Pubkey: e.pubkey}
		return true
	})
	s.mu.Lock()
	s.data.Rejects = out
	s.mu.Unlock()
}

// loadRejects fills t with the saved rejects newer than cutoff. The next
// round's reevaluate still re-offers any whose author the WoT now admits.
func (s *syncState) loadRejects(t *tempRejects, cutoff nostr.Timestamp) {
	if s == nil || t == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, r := range s.data.Rejects {
		if nostr.Timestamp(r.TS) >= cutoff {
			t.add(id, nostr.Timestamp(r.TS), r.Pubkey)
		}
	}
}

// save writes the state if it changed since the last write.
func (s *syncState) save() {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, err := json.Marshal(s.data)
	if err != nil || bytes.Equal(raw, s.last) {
		return
	}
	_ = s.fs.MkdirAll(filepath.Dir(s.path), 0o755)
	tmp := s.path + ".tmp"
	if err := afero.WriteFile(s.fs, tmp, raw, 0o600); err != nil {
		slog.Error("🚫 could not save sync state", "path", s.path, "error", err)
		return
	}
	if err := s.fs.Rename(tmp, s.path); err != nil {
		_ = s.fs.Remove(tmp)
		slog.Error("🚫 could not save sync state", "path", s.path, "error", err)
		return
	}
	s.last = raw
}
