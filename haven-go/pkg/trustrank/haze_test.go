package trustrank

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

// Logen's picks: 1,000 a ring at hop 3, 2,000 at hop 4, no hop-5 haze.
func TestHazeTotalsAreLogensPicks(t *testing.T) {
	if HazeTotal[3] != 1000 || HazeTotal[4] != 2000 || HazePerRing(5) != 0 || HazePerRing(2) != 0 {
		t.Fatalf("haze totals %v", HazeTotal)
	}
	if HazePerRing(3) != 700 || HazePerRing(4) != 1700 {
		t.Fatalf("per-ring caps %d %d", HazePerRing(3), HazePerRing(4))
	}
}

// Ring 3 of globeMap has 350 people: its top 300 are `globe`, the rest
// (shown above 0, owner-muted h(349) left out) are its haze, best first.
func TestHazeIsTheRingAfterItsGlobeTop(t *testing.T) {
	g, owner, h, _ := globeMap()
	res := mustRank(t, g, owner, nil)
	globe := res.Globe(GlobePerRing)
	haze := res.Haze(globe)

	var want []string
	var n int
	for _, p := range res.People() {
		if p.Hop != 3 || p.Pubkey == h(349) || ShownRounded(p.Score) == 0 {
			continue
		}
		if n++; n > GlobePerRing {
			want = append(want, p.Pubkey)
		}
	}
	if len(want) == 0 {
		t.Fatal("map has no ring-3 people past the top, so this test proves nothing")
	}
	var got []string
	last := 101.0
	inGlobe := map[string]bool{}
	for _, r := range globe {
		inGlobe[r[0].(string)] = true
	}
	for _, r := range haze["3"] {
		pk, s := r[0].(string), r[1].(float64)
		if s <= 0 || s > last || inGlobe[pk] || pk == h(349) {
			t.Fatalf("row %v: shown 0, out of order, muted or also in globe", r)
		}
		last = s
		got = append(got, pk)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ring 3 haze %d rows, want %d", len(got), len(want))
	}
	for k := range haze {
		if k != "3" && k != "4" {
			t.Fatalf("haze ring %q", k)
		}
	}

	// A smaller total caps the ring at total - GlobePerRing.
	old := HazeTotal[3]
	HazeTotal[3] = GlobePerRing + 5
	defer func() { HazeTotal[3] = old }()
	if small := res.Haze(globe); len(small["3"]) != 5 || !reflect.DeepEqual(small["3"], haze["3"][:5]) {
		t.Fatalf("cap 5: %d rows", len(small["3"]))
	}
}

// Haze rows never change `people` or `globe`; the writer drops a haze
// over its cap; the hand-off carries a good haze whole and drops a bad one
// while keeping the rest of the copy.
func TestHazeThroughFileAndHandoff(t *testing.T) {
	g, owner, _, _ := globeMap()
	res := mustRank(t, g, owner, nil)
	globe := globeForFile(res.Globe(GlobePerRing))
	haze := hazeForFile(res.Haze(globe))
	if len(haze["3"]) == 0 {
		t.Fatal("no haze, so this test proves nothing")
	}
	dir, plain := t.TempDir(), t.TempDir()
	if err := writeResult(dir, res, globe, haze, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	if err := writeResult(plain, res, globe, nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	f, err := ReadResult(dir, owner)
	if err != nil {
		t.Fatal(err)
	}
	p, _ := ReadResult(plain, owner)
	if !reflect.DeepEqual(f.People, p.People) || !reflect.DeepEqual(f.Globe, p.Globe) || f.MaxHop != p.MaxHop {
		t.Fatal("people, globe or maxHop changed with the haze")
	}
	copy := f.Handoff(HandoffFloor)
	if len(copy.Haze["3"]) != len(haze["3"]) {
		t.Fatalf("hand-off haze %d rows, want %d", len(copy.Haze["3"]), len(haze["3"]))
	}
	raw, _ := json.Marshal(copy)
	if _, err := CheckHandoff(raw, owner); err != nil {
		t.Fatalf("a good copy refused: %v", err)
	}
	row0 := copy.Haze["3"][0]
	bad := func(name string, change func(*ResultFile)) {
		t.Helper()
		c := copy
		c.Haze = map[string][][2]any{"3": append([][2]any(nil), copy.Haze["3"]...)}
		change(&c)
		b, _ := json.Marshal(c)
		got, err := CheckHandoff(b, owner)
		if err != nil {
			t.Errorf("%s: whole copy refused (%v)", name, err)
			return
		}
		if got.Haze != nil {
			t.Errorf("%s: bad haze kept", name)
		}
		if !reflect.DeepEqual(got.People, c.People) || !reflect.DeepEqual(got.Globe, c.Globe) {
			t.Errorf("%s: people or globe changed", name)
		}
	}
	bad("hop-5 haze", func(c *ResultFile) { c.MaxHop = 5; c.Haze["5"] = [][2]any{{pk(30000), 10.0}} })
	bad("hop-2 haze", func(c *ResultFile) { c.Haze["2"] = [][2]any{{pk(30000), 10.0}} })
	bad("ring not a number", func(c *ResultFile) { c.Haze["03"] = [][2]any{{pk(30000), 10.0}} })
	bad("past maxHop", func(c *ResultFile) {
		// Cut the file to ring 3 so only the haze is past maxHop.
		c.MaxHop = 3
		var people [][3]any
		for _, r := range c.People {
			if _, _, hop, _ := row(r); hop <= 3 {
				people = append(people, r)
			}
		}
		var globe [][4]any
		for _, r := range c.Globe {
			if _, _, hop, _, _ := globeRow(r); hop <= 3 {
				globe = append(globe, r)
			}
		}
		c.People, c.Globe = people, globe
		c.Haze["4"] = [][2]any{{pk(30000), 10.0}}
	})
	bad("shown 0", func(c *ResultFile) { c.Haze["3"][0] = [2]any{row0[0], 0.0} })
	bad("shown 101", func(c *ResultFile) { c.Haze["3"][0] = [2]any{row0[0], 101.0} })
	bad("not hex", func(c *ResultFile) { c.Haze["3"][0] = [2]any{"nope", 10.0} })
	bad("in globe too", func(c *ResultFile) { c.Haze["3"][0] = [2]any{c.Globe[0][0], 10.0} })
	bad("twice", func(c *ResultFile) { c.Haze["3"] = append(c.Haze["3"], row0) })
	bad("over the cap", func(c *ResultFile) {
		for i := len(c.Haze["3"]); i <= HazePerRing(3); i++ {
			c.Haze["3"] = append(c.Haze["3"], [2]any{pk(40000 + i), 10.0})
		}
	})

	// A full ring is kept; one row over and the writer leaves the haze out
	// while the copy keeps its feed rows and globe.
	full := map[string][][2]any{"3": nil, "4": nil}
	for h, k := range map[int]string{3: "3", 4: "4"} {
		for i := 0; i < HazePerRing(h); i++ {
			full[k] = append(full[k], [2]any{pk(50000 + h*10000 + i), 10.0})
		}
	}
	c := copy
	c.MaxHop, c.Haze = max(c.MaxHop, 4), full
	b, _ := json.Marshal(c)
	if _, err := CheckHandoff(b, owner); err != nil {
		t.Fatalf("a full haze refused: %v", err)
	}
	if got := hazeForFile(full); got == nil {
		t.Fatal("writer dropped a haze at the cap")
	}
	full["4"] = append(full["4"], [2]any{pk(90000), 10.0})
	if got := hazeForFile(full); got != nil {
		t.Fatal("writer kept a haze over the cap")
	}
	if got := hazeForFile(map[string][][2]any{"5": {{pk(90001), 10.0}}}); got != nil {
		t.Fatal("writer kept a hop-5 haze")
	}
	c.Haze = hazeForFile(full)
	b, _ = json.Marshal(c)
	if k, err := CheckHandoff(b, owner); err != nil || len(k.People) == 0 || len(k.Globe) == 0 {
		t.Fatalf("copy with the haze left out refused or empty: %v", err)
	}
}
