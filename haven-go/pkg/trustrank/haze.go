package trustrank

import (
	"strconv"
)

// The globe haze (Logen 2026-11-24): picking Hop 3 or Hop 4 on the globe
// zooms out, and that ring shows as a haze of the people ranked after its
// top GlobePerRing (those stay in `globe` and stay tappable). Haze dots
// cannot be tapped and carry no chain, so a row is only [pubkey, shown].
// Rows are grouped by ring, best first; a device places the best nearest
// the centre. There is no hop-5 haze (Logen's pick).

// HazeTotal is how many people a ring shows in all, its `globe` top
// included: 1,000 at hop 3 and 2,000 at hop 4. A ring's haze holds at most
// HazeTotal - GlobePerRing rows.
var HazeTotal = map[int]int{3: 1000, 4: 2000}

// HazePerRing is the most haze rows a ring may carry.
func HazePerRing(hop int) int {
	return max(HazeTotal[hop]-GlobePerRing, 0)
}

// Haze is the result file's haze: for each haze ring, the people ranked
// after that ring's top GlobePerRing, best first, as [pubkey, shown].
// Owner-muted people, anyone who shows 0, and anyone already a `globe`
// row (top or chain link) are left out, so nobody is in both lists.
func (r *Result) Haze(globe [][4]any) map[string][][2]any {
	inGlobe := make(map[string]bool, len(globe))
	for _, g := range globe {
		if pk, ok := g[0].(string); ok {
			inGlobe[pk] = true
		}
	}
	seen := map[int]int{} // per ring: shown-above-0 people passed, globe top included
	out := map[string][][2]any{}
	for _, p := range r.People() {
		total := HazeTotal[p.Hop]
		if total == 0 || seen[p.Hop] >= total {
			continue
		}
		i := r.g.index[p.Pubkey]
		s := ShownRounded(p.Score)
		if r.ownerMuted[i] || s == 0 {
			continue
		}
		seen[p.Hop]++
		if seen[p.Hop] <= GlobePerRing || inGlobe[p.Pubkey] {
			continue // the ring's top: it is in `globe`
		}
		k := strconv.Itoa(p.Hop)
		out[k] = append(out[k], [2]any{p.Pubkey, s})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// hazeForFile: the haze the writer puts in the file, or none when a ring
// is over its cap or not a haze ring, so a haze the hand-off would refuse
// can never cost a device the feed rows or `globe` that travel with it.
func hazeForFile(h map[string][][2]any) map[string][][2]any {
	for k, rows := range h {
		hop, err := strconv.Atoi(k)
		if err != nil || len(rows) > HazePerRing(hop) {
			return nil
		}
	}
	return h
}

// checkHaze: every ring is a haze ring no further than maxHop, within its
// cap; every row is a hex pubkey shown above 0 and at most 100, in no
// other haze ring and not a `globe` row.
func checkHaze(h map[string][][2]any, globe [][4]any, maxHop int) bool {
	if len(h) == 0 {
		return true
	}
	inGlobe := make(map[string]bool, len(globe))
	for _, g := range globe {
		if pk, ok := g[0].(string); ok {
			inGlobe[pk] = true
		}
	}
	seen := map[string]bool{}
	for k, rows := range h {
		hop, err := strconv.Atoi(k)
		if err != nil || strconv.Itoa(hop) != k || HazePerRing(hop) == 0 || hop > maxHop ||
			len(rows) > HazePerRing(hop) {
			return false
		}
		for _, r := range rows {
			pk, okPk := r[0].(string)
			shown, okS := r[1].(float64)
			if !okPk || !okS || !validAccount(pk) || shown <= 0 || shown > 100 || seen[pk] || inGlobe[pk] {
				return false
			}
			seen[pk] = true
		}
	}
	return true
}
