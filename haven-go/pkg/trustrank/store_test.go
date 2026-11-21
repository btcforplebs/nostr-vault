package trustrank

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func pk(i int) string { return fmt.Sprintf("%064x", i+1) }

func openT(t *testing.T, dir string, cap int64) *Store {
	t.Helper()
	s, err := OpenStore(dir, cap)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestStoreRoundTripAndRank(t *testing.T) {
	dir := t.TempDir()
	s := openT(t, dir, 0)
	if ok, err := s.Put(pk(0), 10, []string{pk(1), pk(2)}, nil); !ok || err != nil {
		t.Fatal(ok, err)
	}
	s.Put(pk(1), 10, []string{pk(3)}, []string{pk(4)})
	s.Put(pk(2), 10, []string{pk(3), pk(4), "not-a-key"}, nil)
	s.Close()

	s = openT(t, dir, 0)
	if s.Lists() != 3 {
		t.Fatalf("lists %d", s.Lists())
	}
	g, err := s.Graph()
	if err != nil {
		t.Fatal(err)
	}
	r, err := Rank(g, pk(0), nil, DefaultParams())
	if err != nil {
		t.Fatal(err)
	}
	if _, hop, ok := r.Score(pk(3)); !ok || hop != 2 {
		t.Fatalf("pk3 hop %d ok %v", hop, ok)
	}
	if why := r.Explain(pk(4), 0); len(why) != 2 || !(why[0].Muted || why[1].Muted) {
		t.Fatalf("mute lost on the way through disk: %+v", why)
	}
}

func TestStoreNewestWinsAndCompacts(t *testing.T) {
	dir := t.TempDir()
	s := openT(t, dir, 0)
	s.Put(pk(0), 10, []string{pk(1)}, nil)
	if ok, _ := s.Put(pk(0), 9, []string{pk(2)}, nil); ok {
		t.Fatal("an older list must be ignored")
	}
	if ok, _ := s.Put(pk(0), 10, []string{pk(2)}, nil); ok {
		t.Fatal("the same time must be ignored")
	}
	s.Put(pk(0), 11, []string{pk(2)}, nil)
	before := s.Bytes()
	if err := s.Compact(); err != nil {
		t.Fatal(err)
	}
	if s.Bytes() >= before {
		t.Fatalf("compact did not shrink: %d -> %d", before, s.Bytes())
	}
	if at, _ := s.CreatedAt(pk(0)); at != 11 {
		t.Fatalf("createdAt %d", at)
	}
	g, _ := s.Graph()
	r, _ := Rank(g, pk(0), nil, DefaultParams())
	if _, _, ok := r.Score(pk(2)); !ok {
		t.Fatal("newest list lost by compact")
	}
	if _, _, ok := r.Score(pk(1)); ok {
		t.Fatal("old list survived compact")
	}
	s.Put(pk(5), 1, []string{pk(0)}, nil) // still writable after the swap
	s.Close()
	if s2 := openT(t, dir, 0); s2.Lists() != 2 {
		t.Fatalf("reopen after compact: %d lists", s2.Lists())
	}
}

func TestStoreCutsAHalfWrittenRecord(t *testing.T) {
	dir := t.TempDir()
	s := openT(t, dir, 0)
	s.Put(pk(0), 1, []string{pk(1)}, nil)
	s.Put(pk(1), 1, []string{pk(2)}, nil)
	s.Close()
	lists := filepath.Join(dir, "lists.bin")
	st, _ := os.Stat(lists)
	os.Truncate(lists, st.Size()-3) // the app stopped mid-write
	f, _ := os.OpenFile(filepath.Join(dir, "keys.bin"), os.O_APPEND|os.O_WRONLY, 0)
	f.Write([]byte{1, 2, 3}) // and mid-key
	f.Close()
	s = openT(t, dir, 0)
	if s.Lists() != 1 {
		t.Fatalf("want the 1 whole record, got %d", s.Lists())
	}
	if ok, err := s.Put(pk(1), 2, []string{pk(3)}, nil); !ok || err != nil {
		t.Fatal("must be writable after the cut", ok, err)
	}
	s.Close()
	if openT(t, dir, 0).Lists() != 2 {
		t.Fatal("record after the cut lost")
	}
}

func TestStoreCapAndClear(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "wot_deep")
	s := openT(t, dir, 400)
	var err error
	n := 0
	for ; n < 100 && err == nil; n++ {
		_, err = s.Put(pk(n), 1, []string{pk(n + 1000)}, nil)
	}
	if err != ErrFull {
		t.Fatalf("want ErrFull, got %v", err)
	}
	if s.Bytes() > 400 {
		t.Fatalf("over the cap: %d", s.Bytes())
	}
	g, err := s.Graph()
	if err != nil || g.Size() != len(s.keys) {
		t.Fatal("a refused Put must not leave keys behind", err)
	}
	if err := s.Clear(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("Clear must delete the store")
	}
}

func TestStoreRefusesBadInput(t *testing.T) {
	s := openT(t, t.TempDir(), 0)
	if _, err := s.Put("npub1abc", 1, nil, nil); err == nil {
		t.Fatal("rater must be hex")
	}
	big := make([]string, maxListLen+1)
	for i := range big {
		big[i] = pk(i)
	}
	if _, err := s.Put(pk(0), 1, big, nil); err == nil {
		t.Fatal("an oversized list must be refused")
	}
}

func TestStateCheckpoint(t *testing.T) {
	dir := t.TempDir()
	if st := LoadState(dir, pk(0)); st.Account != pk(0) || st.Hop != 0 {
		t.Fatalf("fresh %+v", st)
	}
	want := State{Account: pk(0), ParamsVersion: 2, Hop: 2, Next: 1234, FullAt: 99}
	if err := SaveState(dir, want); err != nil {
		t.Fatal(err)
	}
	if got := LoadState(dir, pk(0)); got != want {
		t.Fatalf("got %+v", got)
	}
	os.WriteFile(StatePath(dir, pk(0)), []byte("{half"), 0o600)
	if st := LoadState(dir, pk(0)); st.Next != 0 {
		t.Fatal("a damaged checkpoint must start over")
	}
	if _, err := os.Stat(StatePath(dir, pk(0)) + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("temp file left behind")
	}
}

func TestStateRefusesABadAccount(t *testing.T) {
	dir := t.TempDir()
	for _, acct := range []string{"../escape", "abc", pk(0)[:63] + "g"} {
		if err := SaveState(dir, State{Account: acct, Next: 5}); err == nil {
			t.Fatalf("%q saved", acct)
		}
		if st := LoadState(dir, acct); st.Next != 0 {
			t.Fatalf("%q loaded %+v", acct, st)
		}
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("files written: %v", left)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "escape.json")); !os.IsNotExist(err) {
		t.Fatal("wrote outside dir")
	}
}

// A list number past the end of keys.bin (keys.bin lost its tail in a power
// loss) must cut the record on open, not later point at an unrelated key.
func TestStoreCutsAListPointingPastKeys(t *testing.T) {
	dir := t.TempDir()
	s := openT(t, dir, 0)
	s.Put(pk(0), 1, []string{pk(1)}, nil) // keys a b
	s.Put(pk(2), 1, []string{pk(3)}, nil) // keys c d
	s.Close()
	kp := filepath.Join(dir, "keys.bin")
	st, _ := os.Stat(kp)
	os.Truncate(kp, st.Size()-32) // d is gone; c's list still names it

	s = openT(t, dir, 0)
	if s.Lists() != 1 {
		t.Fatalf("lists %d, want only a's", s.Lists())
	}
	if _, ok := s.CreatedAt(pk(2)); ok {
		t.Fatal("c's list should be cut so the crawl reads it again")
	}
	if _, err := s.Graph(); err != nil {
		t.Fatal(err)
	}
	s.Put(pk(0), 2, []string{pk(1), pk(4)}, nil) // e takes d's old number
	s.Close()

	s = openT(t, dir, 0)
	g, err := s.Graph()
	if err != nil {
		t.Fatal(err)
	}
	if c := g.index[pk(2)]; len(g.follows[c]) != 0 {
		t.Fatalf("c follows %v; its list was cut", g.follows[c])
	}
	if s.Lists() != 1 {
		t.Fatalf("lists %d", s.Lists())
	}
}

func TestStoreCheckpointSyncsFirst(t *testing.T) {
	dir := t.TempDir()
	s := openT(t, dir, 0)
	s.Put(pk(0), 1, []string{pk(1)}, nil)
	if err := s.Checkpoint(dir, State{Account: pk(0), Hop: 1, Next: 1}); err != nil {
		t.Fatal(err)
	}
	if got := LoadState(dir, pk(0)); got.Next != 1 {
		t.Fatalf("got %+v", got)
	}
	s.Close()
	if err := s.Checkpoint(dir, State{Account: pk(0), Next: 2}); err == nil {
		t.Fatal("a failed sync must not save the checkpoint")
	}
	if got := LoadState(dir, pk(0)); got.Next != 1 {
		t.Fatalf("checkpoint moved past a failed sync: %+v", got)
	}
}

// The owner seen only inside someone else's list was never read, so Rank
// must refuse it the same way it does for a Graph built with SetList.
func TestStoreGraphOwnerListMustBeRead(t *testing.T) {
	s := openT(t, t.TempDir(), 0)
	s.Put(pk(1), 10, []string{pk(0)}, nil)
	g, err := s.Graph()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Rank(g, pk(0), nil, DefaultParams()); err == nil {
		t.Fatal("owner without a stored list must not rank")
	}
	if _, err := Rank(g, pk(1), nil, DefaultParams()); err != nil {
		t.Fatal(err)
	}
}

// Each kind keeps its own time: an older copy of one kind never replaces the
// stored one, even when the other kind is newer; a reopen keeps both times.
func TestStorePutListKindByKind(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	s.PutList(pk(0), List{FollowsAt: 300, Follows: []string{pk(2)}, MutesAt: 50, Mutes: []string{pk(5)}})
	if ok, _ := s.PutList(pk(0), List{FollowsAt: 100, Follows: []string{pk(1)}, MutesAt: 50}); ok {
		t.Fatal("nothing newer: must be refused")
	}
	if ok, err := s.PutList(pk(0), List{FollowsAt: 100, Follows: []string{pk(1)}, MutesAt: 400, Mutes: []string{pk(3)}}); !ok || err != nil {
		t.Fatalf("newer mutes: %v %v", ok, err)
	}
	check := func(s *Store) {
		t.Helper()
		f, m := storedList(t, s, pk(0))
		if len(f) != 1 || f[0] != pk(2) || len(m) != 1 || m[0] != pk(3) {
			t.Fatalf("follows %v mutes %v", f, m)
		}
	}
	check(s)
	// Follows @200 is newer than the stored follows (@300)? No: refused per kind.
	if ok, _ := s.PutList(pk(0), List{FollowsAt: 200, Follows: []string{pk(1)}}); ok {
		t.Fatal("older follows must be refused")
	}
	// A newer follows list with no mutes read keeps the stored mutes.
	if ok, _ := s.PutList(pk(0), List{FollowsAt: 500, Follows: []string{pk(2)}}); !ok {
		t.Fatal("newer follows refused")
	}
	check(s)
	s.Close()
	s2, err := OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	check(s2)
	if ok, _ := s2.PutList(pk(0), List{FollowsAt: 450, MutesAt: 399, Follows: []string{pk(1)}}); ok {
		t.Fatal("per-kind times must survive a reopen")
	}
}
