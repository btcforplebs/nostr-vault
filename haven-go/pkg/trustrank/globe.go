package trustrank

import "sort"

// The globe list (Logen 2026-11-23): the globe shows the best few hundred
// people of each far ring (hops GlobeFromHop to GlobeHop), whatever their
// score, faded the further out they are, and each one can be walked back
// to the owner. The feed does not read it: it keeps `people` and its bar.

const (
	// GlobeFromHop: the nearest ring the globe list covers. Rings 1 and 2
	// are drawn from `people`.
	GlobeFromHop = 3
	// GlobeHop: the furthest ring the globe list covers.
	GlobeHop = 5
	// GlobePerRing: how many people each ring shows, best first.
	GlobePerRing = 300
	// maxGlobeRows bounds a copy's globe list. Chain links need links of
	// their own, so they pile up ring by ring: ring 5 holds its top (1×),
	// ring 4 its top plus a link for each ring-5 row (2×), ring 3 its top
	// plus a link for each ring-4 row (3×), and ring 2 a link for each
	// ring-3 row (3×): at most 9 × GlobePerRing = 2,700 rows.
	maxGlobeRows = 9 * GlobePerRing
)

// globeForFile: the globe list the writer puts in the file, or none when
// it is over maxGlobeRows, so a globe the hand-off would refuse can never
// cost a device the feed rows that travel with it.
func globeForFile(rows [][4]any) [][4]any {
	if len(rows) > maxGlobeRows {
		return nil
	}
	return rows
}

// Globe is the result file's globe list: rows [pubkey, shown, hop, via].
// via is the person's highest-scored follower one ring nearer, the next
// link of the chain back to the owner. For each ring from GlobeFromHop to
// GlobeHop it holds that ring's top perRing people (owner-muted people and
// anyone who shows 0 left out), best first; then the chain links that are
// not already a row, so every row walks back to ring 1 with no relay call.
// Within a hop the ring's top rows come before its chain-link rows. A top
// row always shows above 0, and a full ring's links come after its first
// perRing rows, so a hop's top is its first perRing rows that show above 0
// (a short ring's links follow its top at once and show 0). Hop-2 rows
// are only ever chain links; ring-1 links are in `people` (always kept).
func (r *Result) Globe(perRing int) [][4]any {
	top := map[int][]int32{}
	for _, p := range r.People() {
		i := r.g.index[p.Pubkey]
		if p.Hop < GlobeFromHop || p.Hop > GlobeHop || len(top[p.Hop]) >= perRing ||
			r.ownerMuted[i] || ShownRounded(p.Score) == 0 {
			continue
		}
		top[p.Hop] = append(top[p.Hop], i)
	}
	inList := map[int32]bool{}
	var rows []int32
	for h := GlobeFromHop; h <= GlobeHop; h++ {
		for _, i := range top[h] {
			inList[i] = true
			rows = append(rows, i)
		}
	}
	// Walk outside in, so a ring's chain links get their own via when the
	// next ring in is done.
	via := map[int32]int32{}
	for h := GlobeHop; h >= 2; h-- {
		var ring []int32
		for _, i := range rows {
			if int(r.hop[i]) == h {
				ring = append(ring, i)
			}
		}
		best := r.bestFollowers(ring, h)
		var links []int32
		for _, i := range ring {
			u, ok := best[i]
			if !ok {
				continue // cannot happen for a scored row; left without a link
			}
			via[i] = u
			if r.hop[u] >= 2 && !inList[u] {
				inList[u] = true
				links = append(links, u)
			}
		}
		sort.Slice(links, func(a, b int) bool { return r.better(links[a], links[b]) })
		rows = append(rows, links...)
	}
	sort.SliceStable(rows, func(a, b int) bool { return r.hop[rows[a]] < r.hop[rows[b]] })
	out := make([][4]any, 0, len(rows))
	for _, i := range rows {
		v := ""
		if u, ok := via[i]; ok {
			v = r.g.keys[u]
		}
		out = append(out, [4]any{r.g.keys[i], ShownRounded(r.trust[i] * 100), int(r.hop[i]), v})
	}
	return out
}

// bestFollowers: for each of ring (all at hop h), its highest-scored
// follower at hop h-1 that the owner has not muted.
func (r *Result) bestFollowers(ring []int32, h int) map[int32]int32 {
	want := map[int32]bool{}
	for _, i := range ring {
		want[i] = true
	}
	best := map[int32]int32{}
	if len(want) == 0 {
		return best
	}
	for u := int32(0); int(u) < len(r.g.keys); u++ {
		if int(r.hop[u]) != h-1 || r.ownerMuted[u] || u == r.owner {
			continue
		}
		for _, v := range r.g.follows[u] {
			if !want[v] {
				continue
			}
			if b, ok := best[v]; !ok || r.better(u, b) {
				best[v] = u
			}
		}
	}
	return best
}

// better: People's order (higher score, then nearer, then pubkey).
func (r *Result) better(a, b int32) bool {
	if r.trust[a] != r.trust[b] {
		return r.trust[a] > r.trust[b]
	}
	if r.hop[a] != r.hop[b] {
		return r.hop[a] < r.hop[b]
	}
	return r.g.keys[a] < r.g.keys[b]
}

// globeRow reads one [pubkey, shown, hop, via] row as JSON hands it back.
func globeRow(r [4]any) (pk string, shown float64, hop int, via string, ok bool) {
	pk, shown, hop, ok = row([3]any{r[0], r[1], r[2]})
	via, okV := r[3].(string)
	return pk, shown, hop, via, ok && okV && validAccount(via)
}
