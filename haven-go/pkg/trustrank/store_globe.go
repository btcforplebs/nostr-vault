package trustrank

import (
	"encoding/hex"
	"os"
	"path/filepath"
)

// Globe-only lists (Logen 2026-11-23): the globe step (globewalk.go) reads
// lists the depth rule did not, to find ring 5 for the globe. Those lists
// must never move a feed score (their mutes would lower people in rings
// 1-3), so each one is marked here and the feed's graph is built without
// them. A list the feed walk reads later loses its mark and counts again.
//
// The marks are keyed by pubkey, not by store number, in globe_only.bin
// (32 bytes each), written whole through a temp file and a rename. A mark
// is saved before its list is stored and dropped only after the feed walk
// has read the list, so a power loss can leave a mark with no list
// (harmless), never a globe-only list without its mark.

const globeMarksFile = "globe_only.bin"

type globeMarks struct {
	set map[[32]byte]bool
}

// marksLocked loads the marks on first use. s.mu is held.
func (s *Store) marksLocked() *globeMarks {
	if s.globe != nil {
		return s.globe
	}
	m := &globeMarks{set: map[[32]byte]bool{}}
	if b, err := os.ReadFile(filepath.Join(s.dir, globeMarksFile)); err == nil {
		for i := 0; i+32 <= len(b); i += 32 {
			var k [32]byte
			copy(k[:], b[i:i+32])
			m.set[k] = true
		}
	}
	s.globe = m
	return m
}

// saveMarksLocked writes the marks through a temp file and a rename. s.mu
// is held.
func (s *Store) saveMarksLocked() error {
	buf := make([]byte, 0, len(s.globe.set)*32)
	for k := range s.globe.set {
		buf = append(buf, k[:]...)
	}
	path := filepath.Join(s.dir, globeMarksFile)
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(buf); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

func pubkeyBytes(pk string) ([32]byte, bool) {
	var k [32]byte
	if len(pk) != 64 {
		return k, false
	}
	_, err := hex.Decode(k[:], []byte(pk))
	return k, err == nil
}

// MarkGlobe marks raters' lists as read for the globe only. Call it before
// their lists are stored.
func (s *Store) MarkGlobe(raters []string) error {
	return s.setMarks(raters, true)
}

// UnmarkGlobe drops the mark from raters the feed walk read, so their
// lists count in the feed again. The file is written only when a mark
// goes.
func (s *Store) UnmarkGlobe(raters []string) error {
	return s.setMarks(raters, false)
}

func (s *Store) setMarks(raters []string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.marksLocked()
	changed := false
	for _, pk := range raters {
		k, ok := pubkeyBytes(pk)
		if !ok || m.set[k] == on {
			continue
		}
		if on {
			m.set[k] = true
		} else {
			delete(m.set, k)
		}
		changed = true
	}
	if !changed {
		return nil
	}
	return s.saveMarksLocked()
}

// GlobeOnly reports whether rater's list is marked as read for the globe
// only.
func (s *Store) GlobeOnly(rater string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := pubkeyBytes(rater)
	return ok && s.marksLocked().set[k]
}

// GlobeMarks is how many lists are marked.
func (s *Store) GlobeMarks() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.marksLocked().set)
}

// FeedGraph is Graph without the globe-only lists: their raters stay in the
// table (as people others follow) but have no list, exactly as if the
// lists had never been read.
func (s *Store) FeedGraph() (*Graph, error) {
	g, err := s.Graph()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	marks := s.marksLocked().set
	for k := range marks {
		if id, ok := s.ids[k]; ok {
			g.follows[id], g.mutes[id] = nil, nil
			delete(g.listed, int32(id))
		}
	}
	s.mu.Unlock()
	return g, nil
}
