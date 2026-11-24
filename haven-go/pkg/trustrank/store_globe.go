package trustrank

import (
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// Globe-only lists (Logen 2026-11-23): the globe step (globewalk.go) reads
// lists the depth rule did not, to find ring 5 for the globe. Those lists
// must never move a feed score (their mutes would lower people in rings
// 1-3), so each one is marked here and the feed's graph is built without
// them. A list the feed walk reads later loses its mark and counts again.
//
// The store is shared by every account on the device, but marks are each
// account's own (Tron, #2489): one account's globe step must never take a
// list out of another account's feed, and one account's feed read must
// never put another's globe-only list back. They are keyed by pubkey, not
// by store number, in globe_only_<account>.bin (32 bytes each), written
// whole through a temp file and a rename; PruneAccounts removes the file
// when the account signs out. A mark
// is saved before its list is stored and dropped only after the feed walk
// has read the list, so a power loss can leave a mark with no list
// (harmless), never a globe-only list without its mark.

func globeMarksFile(owner string) string { return "globe_only_" + owner + ".bin" }

type globeMarks struct {
	set map[[32]byte]bool
}

// marksLocked loads owner's marks on first use. s.mu is held.
func (s *Store) marksLocked(owner string) *globeMarks {
	if m := s.globe[owner]; m != nil {
		return m
	}
	m := &globeMarks{set: map[[32]byte]bool{}}
	if b, err := os.ReadFile(filepath.Join(s.dir, globeMarksFile(owner))); validAccount(owner) && err == nil {
		for i := 0; i+32 <= len(b); i += 32 {
			var k [32]byte
			copy(k[:], b[i:i+32])
			m.set[k] = true
		}
	}
	if s.globe == nil {
		s.globe = map[string]*globeMarks{}
	}
	s.globe[owner] = m
	return m
}

// saveMarksLocked writes owner's marks through a temp file and a rename.
// s.mu is held.
func (s *Store) saveMarksLocked(owner string) error {
	if !validAccount(owner) {
		return fmt.Errorf("trustrank: globe marks for a bad account %q", owner)
	}
	m := s.globe[owner]
	buf := make([]byte, 0, len(m.set)*32)
	for k := range m.set {
		buf = append(buf, k[:]...)
	}
	path := filepath.Join(s.dir, globeMarksFile(owner))
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

// MarkGlobe marks raters' lists as read for owner's globe only. Call it
// before their lists are stored.
func (s *Store) MarkGlobe(owner string, raters []string) error {
	return s.setMarks(owner, raters, true)
}

// UnmarkGlobe drops owner's mark from raters owner's feed walk read, so
// their lists count in owner's feed again. The file is written only when a
// mark goes.
func (s *Store) UnmarkGlobe(owner string, raters []string) error {
	return s.setMarks(owner, raters, false)
}

func (s *Store) setMarks(owner string, raters []string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.marksLocked(owner)
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
	return s.saveMarksLocked(owner)
}

// GlobeOnly reports whether rater's list is marked as read for owner's
// globe only.
func (s *Store) GlobeOnly(owner, rater string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := pubkeyBytes(rater)
	return ok && s.marksLocked(owner).set[k]
}

// GlobeMarks is how many lists are marked for owner.
func (s *Store) GlobeMarks(owner string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.marksLocked(owner).set)
}

// FeedGraph is Graph without owner's globe-only lists: their raters stay in
// the table (as people others follow) but have no list, exactly as if the
// lists had never been read.
func (s *Store) FeedGraph(owner string) (*Graph, error) {
	g, err := s.Graph()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	marks := s.marksLocked(owner).set
	for k := range marks {
		if id, ok := s.ids[k]; ok {
			g.follows[id], g.mutes[id] = nil, nil
			delete(g.listed, int32(id))
		}
	}
	s.mu.Unlock()
	return g, nil
}
