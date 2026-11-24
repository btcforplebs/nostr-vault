package trustrank

import (
	"context"
	"sort"
)

// The globe step (Logen 2026-11-23, plan "Walking to hop 5"): the depth
// rule (depth.go) stops the feed walk where a ring adds too few people
// over the outer bar; on most maps that is ring 4, so the globe would have
// no ring 5. After the feed walk stops, the globe step reads the lists of
// the last ring's top GlobePerRing people (by score, whatever it is), and
// so on out to GlobeHop, so the globe finds every ring it draws.
//
// Two ranks keep the feed where it was:
//   - rank A (rankTo, FeedGraph): the lists the feed walk read, as before.
//     It makes `people`, so the feed, the hop line and "why?" never move.
//   - rank B (rankGlobe, Graph): every stored list, globe-only ones
//     included, out to GlobeHop. It makes only `globe`.
//
// Globe-only lists are marked in the store before they are stored
// (store_globe.go), so rank A leaves them out even after a restart.

// walkGlobe reads the globe step's lists, resuming at st's place (st.Globe
// is the ring whose top is being read). st.Hop is the hop the feed walk
// stopped at and is left alone. full: the store reached its cap.
func (c *Crawler) walkGlobe(ctx context.Context, st *State, refresh bool, floor int64) (full bool, err error) {
	if _, stored := c.Store.CreatedAt(c.Owner); !stored {
		return false, nil // no owner list: no map to walk out from
	}
	if st.Globe == 0 {
		// The feed walk found rings out to st.Hop-1 and did not read that
		// ring's lists: the globe step starts there.
		st.Globe, st.Next, st.Last = max(1, st.Hop-1), 0, ""
	}
	for ; st.Globe < c.globeHop(); st.Globe, st.Next, st.Last = st.Globe+1, 0, "" {
		readers, err := c.globeReaders(st.Globe)
		if err != nil {
			return false, err
		}
		if len(readers) == 0 {
			break // an empty ring: nothing further out to find
		}
		// As in the feed walk: the place is the last pubkey read.
		st.Next = sort.SearchStrings(readers, st.Last)
		if st.Next < len(readers) && readers[st.Next] == st.Last && st.Last != "" {
			st.Next++
		}
		full, err = c.readLists(ctx, st, st.Globe+1, readers, refresh, true, floor)
		if err != nil {
			return false, err
		}
		c.Store.Sync()
		if full {
			break
		}
	}
	return full, nil
}

// globeHop is the furthest ring rank B ranks to.
func (c *Crawler) globeHop() int { return max(1, min(GlobeHop, c.Params.MaxHop)) }

// globeReaders: ring's top GlobePerRing people in rank B (the same pick as
// Result.Globe: owner-muted people and anyone who shows 0 left out), in
// pubkey order so the checkpoint's place means the same after a restart.
func (c *Crawler) globeReaders(ring int) ([]string, error) {
	res, err := c.rankGlobe()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, p := range res.People() {
		if len(out) >= GlobePerRing {
			break
		}
		if p.Hop != ring || res.ownerMuted[res.g.index[p.Pubkey]] || ShownRounded(p.Score) == 0 {
			continue
		}
		out = append(out, p.Pubkey)
	}
	sort.Strings(out)
	return out, nil
}

// rankGlobe is rank B: every stored list, out to globeHop.
func (c *Crawler) rankGlobe() (*Result, error) {
	p := c.Params
	p.MaxHop = c.globeHop()
	g, err := c.Store.Graph()
	if err != nil {
		return nil, err
	}
	var blocks []string
	if c.OwnerBlocks != nil {
		blocks = c.OwnerBlocks()
	}
	return Rank(g, c.Owner, blocks, p)
}

// globeRows is the file's globe list from rank B. Only the rows are kept,
// so rank B's graph is gone before rank A builds its own.
func (c *Crawler) globeRows() ([][4]any, error) {
	if _, stored := c.Store.CreatedAt(c.Owner); !stored {
		return nil, nil
	}
	res, err := c.rankGlobe()
	if err != nil {
		return nil, err
	}
	return globeForFile(res.Globe(GlobePerRing)), nil
}

// fileMaxHop: the file's maxHop is the furthest ring in `people` or
// `globe` (rows as Result.Globe makes them). Devices refuse a copy with a
// row past it.
func fileMaxHop(feedHop int, globe [][4]any) int {
	m := feedHop
	for _, r := range globe {
		if h, ok := r[2].(int); ok {
			m = max(m, h)
		}
	}
	return m
}
