package trustrank

import (
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

// globeMap: the owner (pk 0) follows 5 people; each follows the same 10
// (ring 2); ring 3 has 350 people, h(i) followed by i%10+2 of ring 2 (at most 10), so
// ring 3 has 50 more than a ring's cap. Ring 4: k(0) is followed by the
// h(i%10 == 6 or 7) and is ring 4's best, k(1..19) by the h(i%10 == 9). With a cap of 7, ring 3's top
// is only the 10-follower h's, so k(0)'s best follower h(7) must come back
// as a chain link. The owner mutes h(349).
func globeMap() (g *Graph, owner string, h, k func(int) string) {
	owner = pk(0)
	f := func(i int) string { return pk(10 + i) }
	r2 := func(i int) string { return pk(100 + i) }
	h = func(i int) string { return pk(1000 + i) }
	k = func(i int) string { return pk(5000 + i) }
	g = NewGraph()
	var ring1, ring2 []string
	for i := 0; i < 5; i++ {
		ring1 = append(ring1, f(i))
	}
	for i := 0; i < 10; i++ {
		ring2 = append(ring2, r2(i))
	}
	g.SetList(owner, ring1, []string{h(349)})
	for _, p := range ring1 {
		g.SetList(p, ring2, nil)
	}
	for j, p := range ring2 {
		var fs []string
		for i := 0; i < 350; i++ {
			if i%10+1 >= j {
				fs = append(fs, h(i))
			}
		}
		g.SetList(p, fs, nil)
	}
	var ks []string
	for i := 1; i < 20; i++ {
		ks = append(ks, k(i))
	}
	for i := 0; i < 350; i += 10 {
		g.SetList(h(i+6), []string{k(0)}, nil)
		g.SetList(h(i+7), []string{k(0)}, nil)
		g.SetList(h(i+9), ks, nil)
	}
	return g, owner, h, k
}

func TestGlobeListFillsEachRingCappedAndWalksBack(t *testing.T) {
	g, owner, h, k := globeMap()
	res := mustRank(t, g, owner, nil)
	rows := res.Globe(GlobePerRing)

	byPk := map[string][4]any{}
	perHop := map[int][]string{}
	for _, r := range rows {
		p, shown, hop := r[0].(string), r[1].(float64), r[2].(int)
		if _, dup := byPk[p]; dup {
			t.Fatalf("%s twice", p[:8])
		}
		if hop < 2 || hop > GlobeHop || shown <= 0 || shown > 100 {
			t.Fatalf("row %v out of range", r)
		}
		byPk[p] = r
		perHop[hop] = append(perHop[hop], p)
	}
	// Ring 3: its first 300 rows are its top 300 by score, owner-muted left out.
	var want3 []string
	for _, p := range res.People() {
		if p.Hop == 3 && p.Pubkey != h(349) && len(want3) < GlobePerRing {
			want3 = append(want3, p.Pubkey)
		}
	}
	if len(perHop[3]) < GlobePerRing || !reflect.DeepEqual(perHop[3][:GlobePerRing], want3) {
		t.Fatalf("ring 3 top: %d rows, top matches %v", len(perHop[3]),
			len(perHop[3]) >= GlobePerRing && reflect.DeepEqual(perHop[3][:GlobePerRing], want3))
	}
	if _, in := byPk[h(349)]; in {
		t.Error("an owner-muted person is on the globe")
	}
	if len(perHop[3]) != GlobePerRing {
		t.Errorf("ring 3 = %d rows, want the cap (every via is in its top)", len(perHop[3]))
	}
	if len(perHop[4]) != 20 {
		t.Errorf("ring 4 = %d rows, want all 20", len(perHop[4]))
	}
	if byPk[k(0)][3] != h(7) || byPk[k(1)][3] != h(9) { // ties go to the lower pubkey
		t.Error("ring 4 via is not the follower one ring in")
	}
	// Ring 2 rows are chain links only; every row walks back to ring 1.
	if len(perHop[2]) == 0 {
		t.Fatal("no ring-2 chain links")
	}
	for _, r := range rows {
		p, hop := r[0].(string), r[2].(int)
		for hop > 2 {
			next, ok := byPk[r[3].(string)]
			if !ok || next[2].(int) != hop-1 {
				t.Fatalf("%s: via %v is not a globe row one ring in", p[:8], r[3])
			}
			r, hop = next, hop-1
		}
		if _, h1, _ := res.Score(r[3].(string)); h1 != 1 {
			t.Fatalf("%s: chain ends at hop %d, not ring 1", p[:8], h1)
		}
	}
	// A smaller cap: ring 3's 7 best, then h(7) as k(0)'s chain link.
	small := res.Globe(7)
	var ring3 []string
	for _, r := range small {
		if r[2].(int) == 3 {
			ring3 = append(ring3, r[0].(string))
		}
	}
	if !reflect.DeepEqual(ring3, append(append([]string(nil), want3[:7]...), h(7))) {
		t.Errorf("cap 7: ring 3 rows wrong (%d rows)", len(ring3))
	}

	// Through the file and the hand-off: the globe travels whole and is checked.
	dir := t.TempDir()
	if err := writeResult(dir, res, globeForFile(res.Globe(GlobePerRing)), time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	f, err := ReadResult(dir, owner)
	if err != nil {
		t.Fatal(err)
	}
	copy := f.Handoff(HandoffFloor)
	if len(copy.Globe) != len(rows) {
		t.Fatalf("hand-off globe %d rows, want %d", len(copy.Globe), len(rows))
	}
	raw, _ := json.Marshal(copy)
	if _, err := CheckHandoff(raw, owner); err != nil {
		t.Fatalf("a good copy refused: %v", err)
	}
	bad := func(name string, change func(*ResultFile)) {
		t.Helper()
		c := copy
		c.Globe = append([][4]any(nil), copy.Globe...)
		change(&c)
		b, _ := json.Marshal(c)
		if _, err := CheckHandoff(b, owner); !errors.Is(err, ErrBadResult) {
			t.Errorf("%s: kept (%v)", name, err)
		}
	}
	bad("via not hex", func(c *ResultFile) { c.Globe[0] = [4]any{c.Globe[0][0], 10.0, 3, "nope"} })
	bad("no via", func(c *ResultFile) { c.Globe[0] = [4]any{c.Globe[0][0], 10.0, 3, nil} })
	bad("hop 1", func(c *ResultFile) { c.Globe[0] = [4]any{c.Globe[0][0], 10.0, 1, pk(10)} })
	bad("hop 6", func(c *ResultFile) { c.MaxHop = 6; c.Globe[0] = [4]any{c.Globe[0][0], 10.0, 6, pk(10)} })
	bad("past maxHop", func(c *ResultFile) { c.MaxHop = 3; c.Globe[0] = [4]any{c.Globe[0][0], 10.0, 4, pk(10)} })
	bad("score 101", func(c *ResultFile) { c.Globe[0] = [4]any{c.Globe[0][0], 101.0, 3, pk(10)} })
	bad("too many rows", func(c *ResultFile) {
		for len(c.Globe) <= maxGlobeRows {
			c.Globe = append(c.Globe, c.Globe[0])
		}
	})
}

// The feed rows are what they were before the globe list: same rule, same
// order, and every other field of the file unchanged.
func TestGlobeLeavesFeedRowsAlone(t *testing.T) {
	g, owner, _, _ := globeMap()
	res := mustRank(t, g, owner, nil)
	dir := t.TempDir()
	if err := writeResult(dir, res, globeForFile(res.Globe(GlobePerRing)), time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(ResultPath(dir, owner))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]json.RawMessage
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["globe"]; !ok {
		t.Fatal("no globe field, so this test proves nothing")
	}
	delete(got, "globe")

	// The file as the pre-globe writer made it.
	before := ResultFile{Account: owner, BuiltAt: 100, Version: 2, Params: res.Params, MaxHop: res.Params.MaxHop, ViewBar: DefaultViewBar}
	for _, p := range res.People() {
		if s := ShownRounded(p.Score); s != 0 || p.Hop == 1 {
			before.People = append(before.People, [3]any{p.Pubkey, s, p.Hop})
		}
	}
	b, _ := json.Marshal(before)
	var want map[string]json.RawMessage
	_ = json.Unmarshal(b, &want)
	if !reflect.DeepEqual(got, want) {
		t.Fatal("the file's feed fields changed with the globe list")
	}
	f, _ := ReadResult(dir, owner)
	whole := f.Handoff(HandoffFloor)
	f.Globe = nil
	trimmed := f.Handoff(HandoffFloor)
	if !reflect.DeepEqual(whole.People, trimmed.People) || len(whole.People) == 0 {
		t.Fatal("the hand-off's feed rows depend on the globe list")
	}
}

// The cap holds the largest globe the writer can make (9 × GlobePerRing),
// and a globe over it is left out of the file rather than costing the copy
// its feed rows.
func TestGlobeCapFitsTheWorstCase(t *testing.T) {
	if maxGlobeRows < 9*GlobePerRing {
		t.Fatalf("cap %d is under the worst case %d", maxGlobeRows, 9*GlobePerRing)
	}
	g, owner, _, _ := globeMap()
	res := mustRank(t, g, owner, nil)
	dir := t.TempDir()
	if err := writeResult(dir, res, globeForFile(res.Globe(GlobePerRing)), time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	f, err := ReadResult(dir, owner)
	if err != nil {
		t.Fatal(err)
	}
	full := f.Handoff(HandoffFloor)
	// A worst-case globe of 9 × GlobePerRing rows is kept whole.
	full.Globe = nil
	for len(full.Globe) < 9*GlobePerRing {
		full.Globe = append(full.Globe, [4]any{pk(len(full.Globe) + 20000), 10.0, 3, pk(10)})
	}
	raw, _ := json.Marshal(full)
	if _, err := CheckHandoff(raw, owner); err != nil {
		t.Fatalf("a worst-case globe refused: %v", err)
	}
	// One row over: the writer leaves the globe out, the feed rows stay.
	over := append(full.Globe, full.Globe[0])
	if got := globeForFile(over); got != nil {
		t.Fatalf("writer kept a %d-row globe over the cap", len(got))
	}
	if got := globeForFile(full.Globe); len(got) != len(full.Globe) {
		t.Fatal("writer dropped a globe at the cap")
	}
	full.Globe = globeForFile(over)
	raw, _ = json.Marshal(full)
	c, err := CheckHandoff(raw, owner)
	if err != nil || len(c.People) == 0 {
		t.Fatalf("copy with the globe left out refused or empty: %v", err)
	}
}
