package trustrank

// The depth rule (Logen 2026-11-22): how far out the crawl walks is decided
// by trust, not by a fixed number. Rings 1 to SureHop are always walked, as
// before. Past that the crawl goes one ring further only while the last
// ring it found is worth it: that ring must add at least MinRingGain new
// people over the outer bar, measured against everyone nearer who is over
// it. A ring that adds less ends the walk, and CeilingHop ends it whatever
// the rings add ("six degrees").
const (
	// SureHop: the furthest ring found without asking the rule.
	SureHop = 3
	// CeilingHop: the furthest ring ever found. Its lists are never read.
	CeilingHop = 6
	// MinRingGain: the share of new people a ring must add for the crawl
	// to read that ring's lists and so find the next one.
	MinRingGain = 0.01
)

// reads: whether p's own list is read. People in rings 1 and 2 answer to
// Bar (a rank score), as before the rule; people further out answer to
// OuterBar, which is on the shown scale.
func (c *Crawler) reads(res *Result, p Person) bool {
	if p.Hop <= 2 {
		return res.Passes(p.Pubkey, c.Bar)
	}
	return res.PassesShown(p.Pubkey, c.OuterBar)
}

// ringEarnsWalk: whether ring adds enough people over bar (shown scale) for
// its lists to be read. The gain is counted against the people over the
// same bar in every nearer ring.
func ringEarnsWalk(res *Result, ring int, bar float64) bool {
	gain, nearer := 0, 0
	for _, p := range res.People() {
		if p.Hop > ring || !res.PassesShown(p.Pubkey, bar) {
			continue
		}
		if p.Hop == ring {
			gain++
		} else {
			nearer++
		}
	}
	return gain > 0 && float64(gain) >= MinRingGain*float64(nearer)
}

// walks: whether hop h's lists (the people in ring h-1) are read at all.
// resumed: this hop was already under way at the last checkpoint, so the
// answer was yes and is not asked again (lists read since can move it).
func (c *Crawler) walks(res *Result, h int, resumed bool) bool {
	return h <= SureHop || resumed || ringEarnsWalk(res, h-1, c.OuterBar)
}

// rankTo ranks what the store holds out to ring maxHop and no further. The
// pass's result uses the ring this pass reached, so lists left in the store
// by an earlier, deeper pass cannot put people in rings this pass did not
// walk to. Lists read only for the globe are left out (store_globe.go), so
// they never move a feed score.
func (c *Crawler) rankTo(maxHop int) (*Result, error) {
	p := c.Params
	p.MaxHop = max(1, min(maxHop, p.MaxHop))
	g, err := c.Store.FeedGraph()
	if err != nil {
		return nil, err
	}
	var blocks []string
	if c.OwnerBlocks != nil {
		blocks = c.OwnerBlocks()
	}
	return Rank(g, c.Owner, blocks, p)
}
