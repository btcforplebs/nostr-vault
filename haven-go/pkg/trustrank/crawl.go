package trustrank

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// List is one person's follow and mute lists as read from relays. Each kind
// has its own time (0: no relay had that kind).
type List struct {
	FollowsAt int64
	MutesAt   int64
	Follows   []string
	Mutes     []string
}

// Newest is the newer of the two lists' times.
func (l List) Newest() int64 { return max(l.FollowsAt, l.MutesAt) }

// Ask is one person in a batch. Since (0: nothing stored) asks only for
// lists at or after it.
type Ask struct {
	Pubkey string
	Since  int64
}

// Fetcher reads a batch of people's lists. The map holds only the people a
// relay had a list for; an error means "not known", never "no list".
type Fetcher interface {
	Fetch(ctx context.Context, asks []Ask, floor int64) (map[string]List, error)
	// Batch is how many people to ask for next (refresh: a refresh pass).
	Batch(refresh bool) int
}

// refreshFloor: a refresh's REQs ask for nothing older than a day before
// the last finished pass started (State.DoneStart: a pass paused for days
// still read its first people at its start). Asking each person since their own stored list
// (often years old) would read nearly every list again; anything newer than
// the stored list but older than the floor was there at the last pass, so
// it was read then. Missed only: a list backdated by over a day, or a person
// who was not a reader last pass. The weekly full pass reads those.
const refreshFloor = 24 * time.Hour

// Crawler walks out from one owner, reading only the lists of people who
// already pass the bar, a batch at a time, and ranks what it has read.
// It signs nothing and publishes nothing.
type Crawler struct {
	Store  *Store
	Dir    string // state_<account>.json and wot_rank_<account>.json go here
	Owner  string // the account, hex
	Fetch  Fetcher
	Params Params
	// ParamsVersion goes in the checkpoint; a change drops the checkpoint's
	// place and starts the pass again at hop 1 (lists are read again).
	ParamsVersion int
	// Bar (0-100, a rank score): in rings 1 and 2, only people at or over
	// it have their own list read.
	Bar float64
	// OuterBar (0-100, the shown scale): the same for people past ring 2,
	// and the bar the depth rule counts a ring's people against (depth.go).
	OuterBar float64
	// OwnerBlocks returns the owner's public and private mutes and blocks.
	OwnerBlocks func() []string
	// Wait blocks until the crawl may go on (window closed, no copy or
	// import running). False stops the run.
	Wait func(ctx context.Context) bool
	// Pace is the pause after each batch (working: 1 s).
	Pace time.Duration
	// Now is the clock (tests).
	Now func() time.Time
	// Progress, when set, hears hop, place and total after each list.
	Progress func(hop, done, total int)
}

// ErrStopped: Wait said no, or ctx ended. The checkpoint holds the place.
var ErrStopped = errors.New("trustrank: crawl paused")

const checkpointEvery = 50

// maxSkew is how far past now a list's created_at may be. A later one is
// stored as now+maxSkew, so a future-dated list cannot freeze that person's
// list (a refresh asks only for lists newer than the stored time).
const maxSkew = 5 * time.Minute

// RunPass reads every reader's list hop by hop (resuming from the
// checkpoint), ranks, and writes the result. refresh asks only for lists
// newer than the stored ones.
func (c *Crawler) RunPass(ctx context.Context, refresh bool) (*Result, error) {
	st := LoadState(c.Dir, c.Owner)
	if st.ParamsVersion != c.ParamsVersion || st.Hop < 1 || st.Refresh != refresh {
		// New weights, no checkpoint, or a checkpoint of the other kind of
		// pass: start this pass at hop 1.
		st = State{Account: c.Owner, ParamsVersion: c.ParamsVersion, Hop: 1, Refresh: refresh,
			FullAt: st.FullAt, RefreshAt: st.RefreshAt, DoneStart: st.DoneStart}
	}
	if st.PassStart == 0 {
		st.PassStart = c.now().Unix()
	}
	var floor int64
	last := st.DoneStart
	if last == 0 {
		last = max(st.FullAt, st.RefreshAt) // a checkpoint from before DoneStart
	}
	if refresh && last > 0 {
		floor = max(1, last-int64(refreshFloor/time.Second))
	}
	// pause keeps the place: lists on disk first, then the checkpoint.
	pause := func() (*Result, error) {
		c.Store.Checkpoint(c.Dir, st)
		return nil, ErrStopped
	}
	// Hop 1 reads the owner's own list; hop h reads the lists of the people
	// at distance h-1 who pass the bar. Ranking out to MaxHop needs lists
	// out to MaxHop-1. Past SureHop the depth rule (depth.go) says whether
	// a hop is read at all; the first one it turns down ends the walk.
	full := false
	for ; st.Hop <= c.Params.MaxHop && !full; st.Hop, st.Next, st.Last = st.Hop+1, 0, "" {
		readers, walk, err := c.readers(st.Hop, st.Last != "")
		if err != nil {
			return nil, err
		}
		if !walk {
			break
		}
		// The reader list is built again on resume, and lists read earlier
		// in this hop can change it (a mute moves a score across the bar),
		// so the place is the last pubkey read, not an index: go on at the
		// first reader after it (readers are sorted).
		st.Next = sort.SearchStrings(readers, st.Last)
		if st.Next < len(readers) && readers[st.Next] == st.Last && st.Last != "" {
			st.Next++
		}
		lastSave, savedAt := c.now(), st.Next
		for st.Next < len(readers) {
			if !c.Wait(ctx) || ctx.Err() != nil {
				return pause()
			}
			batch := readers[st.Next:min(len(readers), st.Next+max(1, c.Fetch.Batch(refresh)))]
			asks := make([]Ask, len(batch))
			for i, pk := range batch {
				// A full pass reads every list again (a resumed one starts
				// at the checkpoint's place); a refresh asks only for newer.
				asks[i].Pubkey = pk
				if have, stored := c.Store.CreatedAt(pk); stored && refresh {
					asks[i].Since = have + 1
				}
			}
			got, err := c.Fetch.Fetch(ctx, asks, floor)
			if err != nil {
				// No answer (no relay reached, or ctx ended) is not "no
				// list": keep the place (before this batch) and stop, so
				// these people are asked again on the next run.
				c.Store.Checkpoint(c.Dir, st)
				if ctx.Err() != nil {
					return nil, ErrStopped
				}
				return nil, fmt.Errorf("trustrank: lists from %s…: %w", batch[0][:8], err)
			}
			for _, pk := range batch {
				if l, found := got[pk]; found {
					limit := c.now().Add(maxSkew).Unix()
					l.FollowsAt, l.MutesAt = min(l.FollowsAt, limit), min(l.MutesAt, limit)
					// Kind by kind: a stale copy of one kind never replaces
					// a newer stored one, even when the other kind is new.
					if _, err := c.Store.PutList(pk, l); errors.Is(err, ErrFull) {
						full = true // keep what we have and rank it
						break
					}
				}
				st.Last = pk
				st.Next++
			}
			if full {
				break
			}
			if c.Progress != nil {
				c.Progress(st.Hop, st.Next, len(readers))
			}
			if st.Next-savedAt >= checkpointEvery || c.now().Sub(lastSave) > 30*time.Second {
				c.Store.Checkpoint(c.Dir, st)
				lastSave, savedAt = c.now(), st.Next
			}
			if c.Pace > 0 {
				select {
				case <-ctx.Done():
					return pause() // this batch is read; the place is st.Last
				case <-time.After(c.Pace):
				}
			}
		}
		c.Store.Sync()
	}
	// st.Hop is one past the last hop read (or the hop turned down), so the
	// furthest ring this pass found is st.Hop-1.
	res, err := c.rankTo(st.Hop - 1)
	if err != nil {
		return nil, err
	}
	if err := writeResult(c.Dir, res, c.now()); err != nil {
		return nil, err
	}
	st.Hop, st.Next, st.Last, st.Refresh = 1, 0, "", false
	// A pass cut short by a full store is ranked but not counted as done.
	st.Capped = full
	switch {
	case full:
	case refresh:
		st.RefreshAt, st.DoneStart = c.now().Unix(), st.PassStart
	default:
		st.FullAt, st.DoneStart = c.now().Unix(), st.PassStart
	}
	st.PassStart = 0
	c.Store.Compact()
	return res, c.Store.Checkpoint(c.Dir, st)
}

func (c *Crawler) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// readers is who has their list read at hop h, in a fixed order so the
// checkpoint's place means the same thing after a restart. walk is false
// when the depth rule says hop h is not read (resumed: see Crawler.walks).
func (c *Crawler) readers(h int, resumed bool) (out []string, walk bool, err error) {
	if h == 1 {
		return []string{c.Owner}, true, nil
	}
	if _, stored := c.Store.CreatedAt(c.Owner); !stored {
		return nil, true, nil // no owner list: nobody to walk out to
	}
	// Only the people in ring h-1 are looked at, so the rank stops there.
	res, err := c.rankTo(h - 1)
	if err != nil {
		return nil, false, err
	}
	if !c.walks(res, h, resumed) {
		return nil, false, nil
	}
	for _, p := range res.People() {
		if p.Hop == h-1 && c.reads(res, p) {
			out = append(out, p.Pubkey)
		}
	}
	sort.Strings(out)
	return out, true, nil
}

// ResultFile is wot_rank_<account>.json: what the phones read. Never
// published.
type ResultFile struct {
	Account string `json:"account"`
	BuiltAt int64  `json:"builtAt"`
	Version int    `json:"version"`
	Params  Params `json:"params"`
	MaxHop  int    `json:"maxHop"`
	// [pubkey, shown score 0-100 to 0.1, hop]. Version 2: the shown (log)
	// scale (shown.go); version 1 carried the rank score.
	People [][3]any `json:"people"`
	// ViewBar is where the slider starts, on the shown scale.
	ViewBar float64 `json:"viewBar"`
	// Floor is set only on a copy handed to a device (handoff.go): people
	// who show under it were left out.
	Floor float64 `json:"floor,omitempty"`
	// Globe: [pubkey, shown, hop, via] for the globe only (globe.go). Travels
	// whole; the feed never reads it. Older apps ignore it.
	Globe [][4]any `json:"globe,omitempty"`
}

// ResultPath is the result's file for account in dir.
func ResultPath(dir, account string) string {
	return filepath.Join(dir, "wot_rank_"+account+".json")
}

func writeResult(dir string, r *Result, now time.Time) error {
	f := ResultFile{Account: r.Owner, BuiltAt: now.Unix(), Version: 2, Params: r.Params, MaxHop: r.Params.MaxHop, ViewBar: DefaultViewBar}
	for _, p := range r.People() {
		s := ShownRounded(p.Score)
		if s == 0 && p.Hop > 1 {
			continue // nobody trusted vouches for them: not worth the bytes
		}
		f.People = append(f.People, [3]any{p.Pubkey, s, p.Hop})
	}
	f.Globe = globeForFile(r.Globe(GlobePerRing))
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	path := ResultPath(dir, r.Owner)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
