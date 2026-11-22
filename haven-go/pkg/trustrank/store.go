package trustrank

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"math"
	"os"
	"path/filepath"
	"sync"
)

// Store keeps the follow and mute lists the crawler reads, on disk, compact:
// each pubkey once (keys.bin, 32 bytes each, its place is its number) and
// each list as numbers (lists.bin, append-only, the newest record per rater
// wins). Lists are public data, so one store serves every account on the
// device. A record that was half written when the app stopped is cut off on
// the next open.
type Store struct {
	mu       sync.Mutex
	dir      string
	capBytes int64
	keys     [][32]byte
	ids      map[[32]byte]uint32
	latest   map[uint32]entry // rater -> newest record
	keysF    *os.File
	listsF   *os.File
	listsLen int64
	keysLen  int64
	dead     int64 // bytes of records a newer one replaced
}

type entry struct {
	off       int64
	size      int64
	createdAt int64     // the newer of at[0] and at[1]
	at        [2]uint32 // follow list's time, mute list's time
}

func newest(at [2]uint32) int64 { return int64(max(at[0], at[1])) }

// ErrFull: the store reached its cap. The crawl stops and keeps what it has.
var ErrFull = errors.New("trustrank: list store is full")

// rater, follow list's time (uint32), mute list's time (uint32), follows,
// mutes. Each kind keeps its own time so a stale copy of one kind is never
// stored under the other kind's newer time.
const recHeader = 4 + 4 + 4 + 4 + 4

// OpenStore opens (or makes) the store in dir. capBytes bounds keys.bin plus
// lists.bin.
func OpenStore(dir string, capBytes int64) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, capBytes: capBytes, ids: map[[32]byte]uint32{}, latest: map[uint32]entry{}}
	var err error
	if s.keysF, err = os.OpenFile(filepath.Join(dir, "keys.bin"), os.O_RDWR|os.O_CREATE, 0o600); err != nil {
		return nil, err
	}
	if s.listsF, err = os.OpenFile(filepath.Join(dir, "lists.bin"), os.O_RDWR|os.O_CREATE, 0o600); err != nil {
		s.keysF.Close()
		return nil, err
	}
	if err = s.loadKeys(); err == nil {
		err = s.loadLists()
	}
	if err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) loadKeys() error {
	st, err := s.keysF.Stat()
	if err != nil {
		return err
	}
	n := st.Size() / 32
	if st.Size()%32 != 0 { // a half-written key: drop it
		if err := s.keysF.Truncate(n * 32); err != nil {
			return err
		}
	}
	r := bufio.NewReader(io.NewSectionReader(s.keysF, 0, n*32))
	for i := int64(0); i < n; i++ {
		var k [32]byte
		if _, err := io.ReadFull(r, k[:]); err != nil {
			return err
		}
		s.ids[k] = uint32(len(s.keys))
		s.keys = append(s.keys, k)
	}
	s.keysLen = n * 32
	return nil
}

func (s *Store) loadLists() error {
	st, err := s.listsF.Stat()
	if err != nil {
		return err
	}
	r := bufio.NewReader(io.NewSectionReader(s.listsF, 0, st.Size()))
	var off int64
	// Every number in a record, rater and list alike, must be inside
	// keys.bin. After a power loss lists.bin can reach disk before keys.bin
	// does; a number past the end would later point at whatever key is
	// added next, a wrong trust edge. So the file is cut at the first record
	// that fails. The crawl checkpoint is only saved after Sync (see
	// Checkpoint), so lists cut here are read again on the next pass.
	var scratch []uint32
	for {
		rater, at, size, ok := readRecord(r, uint32(len(s.keys)), &scratch)
		if !ok {
			break
		}
		if old, had := s.latest[rater]; had {
			s.dead += old.size
		}
		s.latest[rater] = entry{off: off, size: size, createdAt: newest(at), at: at}
		off += size
	}
	if off < st.Size() {
		if err := s.listsF.Truncate(off); err != nil {
			return err
		}
	}
	s.listsLen = off
	return nil
}

// readRecord reads one record. ids, when not nil, receives the follow then
// mute numbers. ok is false at the end or at a damaged record.
func readRecord(r io.Reader, nKeys uint32, ids *[]uint32) (rater uint32, at [2]uint32, size int64, ok bool) {
	var h [recHeader]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return 0, at, 0, false
	}
	rater = binary.LittleEndian.Uint32(h[0:])
	at = [2]uint32{binary.LittleEndian.Uint32(h[4:]), binary.LittleEndian.Uint32(h[8:])}
	nf := binary.LittleEndian.Uint32(h[12:])
	nm := binary.LittleEndian.Uint32(h[16:])
	n := uint64(nf) + uint64(nm)
	if rater >= nKeys || n > maxListLen*2 {
		return 0, at, 0, false
	}
	body := make([]byte, n*4+4)
	if _, err := io.ReadFull(r, body); err != nil {
		return 0, at, 0, false
	}
	crc := crc32.NewIEEE()
	crc.Write(h[:])
	crc.Write(body[:n*4])
	if crc.Sum32() != binary.LittleEndian.Uint32(body[n*4:]) {
		return 0, at, 0, false
	}
	if ids != nil {
		*ids = (*ids)[:0]
		for i := uint64(0); i < n; i++ {
			id := binary.LittleEndian.Uint32(body[i*4:])
			if id >= nKeys {
				return 0, at, 0, false
			}
			*ids = append(*ids, id)
		}
	}
	return rater, at, int64(recHeader) + int64(len(body)), true
}

// maxListLen: a list longer than this is skipped by the crawler, so one huge
// list cannot blow the memory budget.
const maxListLen = 10000

func (s *Store) keyID(pk string) (uint32, int, error) {
	var k [32]byte
	if len(pk) != 64 {
		return 0, 0, fmt.Errorf("trustrank: %q is not a hex pubkey", pk)
	}
	if _, err := hex.Decode(k[:], []byte(pk)); err != nil {
		return 0, 0, fmt.Errorf("trustrank: %q is not a hex pubkey", pk)
	}
	if id, ok := s.ids[k]; ok {
		return id, 0, nil
	}
	id := uint32(len(s.keys))
	s.ids[k] = id
	s.keys = append(s.keys, k)
	return id, 32, nil
}

// Put stores rater's list as of createdAt (both kinds). An older or equal
// list than the one stored is ignored (returns false). Bad pubkeys in the
// list are skipped; a bad rater is an error. A list over the size limit is
// refused.
func (s *Store) Put(rater string, createdAt int64, follows, mutes []string) (bool, error) {
	return s.PutList(rater, List{FollowsAt: createdAt, MutesAt: createdAt, Follows: follows, Mutes: mutes})
}

// PutList stores rater's lists kind by kind: a kind is replaced only when its
// time is newer than the stored one of that kind; otherwise the stored kind
// is kept. Returns false when neither kind is newer.
func (s *Store) PutList(rater string, l List) (bool, error) {
	if len(l.Follows) > maxListLen || len(l.Mutes) > maxListLen {
		return false, fmt.Errorf("trustrank: list over %d names", maxListLen)
	}
	var at [2]uint32
	for i, t := range [2]int64{l.FollowsAt, l.MutesAt} {
		if t < 0 || t > math.MaxUint32 {
			return false, fmt.Errorf("trustrank: list time %d out of range", t)
		}
		at[i] = uint32(t)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	nKeys := len(s.keys)
	r, newKeys, err := s.keyID(rater)
	if err != nil {
		return false, err
	}
	take := [2]bool{true, true}
	var kept [2][]uint32
	if old, ok := s.latest[r]; ok {
		take = [2]bool{at[0] > old.at[0], at[1] > old.at[1]}
		if !take[0] && !take[1] {
			return false, nil
		}
		var ids []uint32
		sr := io.NewSectionReader(s.listsF, old.off, old.size)
		var h [recHeader]byte
		if _, err := sr.ReadAt(h[:], 0); err != nil {
			return false, err
		}
		nf := binary.LittleEndian.Uint32(h[12:])
		if _, _, _, ok := readRecord(sr, uint32(len(s.keys)), &ids); !ok {
			return false, fmt.Errorf("trustrank: damaged list record at %d", old.off)
		}
		kept = [2][]uint32{ids[:nf], ids[nf:]}
		for i := range take {
			if !take[i] {
				at[i] = old.at[i]
			}
		}
	}
	var parts [2][]uint32
	for i, list := range [2][]string{l.Follows, l.Mutes} {
		if !take[i] {
			parts[i] = kept[i]
			continue
		}
		for _, pk := range list {
			id, added, err := s.keyID(pk)
			if err != nil {
				continue
			}
			newKeys += added
			parts[i] = append(parts[i], id)
		}
	}
	ids := append(append([]uint32{}, parts[0]...), parts[1]...)
	nf := len(parts[0])
	rec := make([]byte, recHeader+len(ids)*4+4)
	binary.LittleEndian.PutUint32(rec[0:], r)
	binary.LittleEndian.PutUint32(rec[4:], at[0])
	binary.LittleEndian.PutUint32(rec[8:], at[1])
	binary.LittleEndian.PutUint32(rec[12:], uint32(nf))
	binary.LittleEndian.PutUint32(rec[16:], uint32(len(ids)-nf))
	for i, id := range ids {
		binary.LittleEndian.PutUint32(rec[recHeader+i*4:], id)
	}
	binary.LittleEndian.PutUint32(rec[len(rec)-4:], crc32.ChecksumIEEE(rec[:len(rec)-4]))
	if s.capBytes > 0 && s.keysLen+int64(newKeys)+s.listsLen+int64(len(rec)) > s.capBytes {
		s.forgetKeys(nKeys)
		return false, ErrFull
	}
	// Keys first: a list never points past the key file.
	if newKeys > 0 {
		buf := make([]byte, 0, newKeys)
		for _, k := range s.keys[nKeys:] {
			buf = append(buf, k[:]...)
		}
		if _, err := s.keysF.WriteAt(buf, s.keysLen); err != nil {
			s.forgetKeys(nKeys)
			return false, err
		}
		s.keysLen += int64(len(buf))
	}
	if _, err := s.listsF.WriteAt(rec, s.listsLen); err != nil {
		return false, err
	}
	if old, ok := s.latest[r]; ok {
		s.dead += old.size
	}
	s.latest[r] = entry{off: s.listsLen, size: int64(len(rec)), createdAt: newest(at), at: at}
	s.listsLen += int64(len(rec))
	return true, nil
}

func (s *Store) forgetKeys(keep int) {
	for _, k := range s.keys[keep:] {
		delete(s.ids, k)
	}
	s.keys = s.keys[:keep]
}

// CreatedAt is the stored list's time for rater, for the crawler's "since".
func (s *Store) CreatedAt(rater string) (int64, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var k [32]byte
	if _, err := hex.Decode(k[:], []byte(rater)); err != nil || len(rater) != 64 {
		return 0, false
	}
	id, ok := s.ids[k]
	if !ok {
		return 0, false
	}
	e, ok := s.latest[id]
	return e.createdAt, ok
}

// Lists is the number of raters with a stored list.
func (s *Store) Lists() int { s.mu.Lock(); defer s.mu.Unlock(); return len(s.latest) }

// Bytes is the store's size on disk.
func (s *Store) Bytes() int64 { s.mu.Lock(); defer s.mu.Unlock(); return s.keysLen + s.listsLen }

// Graph builds a rank graph from every stored list.
func (s *Store) Graph() (*Graph, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := &Graph{index: make(map[string]int32, len(s.keys)), keys: make([]string, len(s.keys)),
		follows: make([][]int32, len(s.keys)), mutes: make([][]int32, len(s.keys)),
		listed: make(map[int32]bool, len(s.latest))}
	for i, k := range s.keys {
		pk := hex.EncodeToString(k[:])
		g.keys[i] = pk
		g.index[pk] = int32(i)
	}
	var ids []uint32
	for rater, e := range s.latest {
		r := io.NewSectionReader(s.listsF, e.off, e.size)
		var h [recHeader]byte
		if _, err := r.ReadAt(h[:], 0); err != nil {
			return nil, err
		}
		nf := binary.LittleEndian.Uint32(h[12:])
		if _, _, _, ok := readRecord(r, uint32(len(s.keys)), &ids); !ok {
			return nil, fmt.Errorf("trustrank: damaged list record at %d", e.off)
		}
		g.setIDs(int32(rater), ids[:nf], ids[nf:])
	}
	return g, nil
}

// setIDs is SetList for numbers already in the table.
func (g *Graph) setIDs(r int32, follows, mutes []uint32) {
	muted := make(map[int32]bool, len(mutes))
	ms := make([]int32, 0, len(mutes))
	for _, m := range mutes {
		t := int32(m)
		if t != r && !muted[t] {
			muted[t] = true
			ms = append(ms, t)
		}
	}
	seen := make(map[int32]bool, len(follows))
	fs := make([]int32, 0, len(follows))
	for _, f := range follows {
		t := int32(f)
		if t != r && !muted[t] && !seen[t] {
			seen[t] = true
			fs = append(fs, t)
		}
	}
	g.follows[r], g.mutes[r] = fs, ms
	g.listed[r] = true
}

// Compact rewrites lists.bin with only the newest record per rater, when
// more than half of it is replaced records. The swap is an atomic rename.
func (s *Store) Compact() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dead*2 < s.listsLen {
		return nil
	}
	tmpPath := filepath.Join(s.dir, "lists.tmp")
	tmp, err := os.OpenFile(tmpPath, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(tmp)
	latest := make(map[uint32]entry, len(s.latest))
	var off int64
	for rater, e := range s.latest {
		buf := make([]byte, e.size)
		if _, err := s.listsF.ReadAt(buf, e.off); err != nil {
			tmp.Close()
			os.Remove(tmpPath)
			return err
		}
		if _, err := w.Write(buf); err != nil {
			tmp.Close()
			os.Remove(tmpPath)
			return err
		}
		latest[rater] = entry{off: off, size: e.size, createdAt: e.createdAt, at: e.at}
		off += e.size
	}
	if err := w.Flush(); err == nil {
		err = tmp.Sync()
	}
	if err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, filepath.Join(s.dir, "lists.bin")); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	s.listsF.Close()
	s.listsF, s.latest, s.listsLen, s.dead = tmp, latest, off, 0
	return nil
}

// Checkpoint syncs the store, then saves st. The checkpoint must never get
// ahead of the lists on disk: a list the checkpoint calls done but that a
// power loss dropped would not be read again until the next full pass.
func (s *Store) Checkpoint(dir string, st State) error {
	if err := s.Sync(); err != nil {
		return err
	}
	return SaveState(dir, st)
}

// Sync flushes both files to disk.
func (s *Store) Sync() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.keysF.Sync(); err != nil {
		return err
	}
	return s.listsF.Sync()
}

// Close closes the files.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var err error
	if s.keysF != nil {
		err = s.keysF.Close()
	}
	if s.listsF != nil {
		if e := s.listsF.Close(); err == nil {
			err = e
		}
	}
	return err
}

// Clear closes the store and deletes it from disk (the Settings "Clear").
func (s *Store) Clear() error {
	s.Close()
	return os.RemoveAll(s.dir)
}
