package trustrank

import (
	"context"
	"encoding/json"
	"errors"
	"math"
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

// Fetcher reads one person's lists. found is false when no relay had them.
type Fetcher interface {
	Fetch(ctx context.Context, pubkey string, since int64) (l List, found bool, err error)
}

// Crawler walks out from one owner, reading only the lists of people who
// already pass the bar, one list at a time, and ranks what it has read.
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
	// Bar (0-100): only people at or over it have their own list read.
	Bar float64
	// OwnerBlocks returns the owner's public and private mutes and blocks.
	OwnerBlocks func() []string
	// Wait blocks until the crawl may go on (window closed, no copy or
	// import running). False stops the run.
	Wait func(ctx context.Context) bool
	// Pace is the pause after each list (working: 1 s).
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
			FullAt: st.FullAt, RefreshAt: st.RefreshAt}
	}
	// pause keeps the place: lists on disk first, then the checkpoint.
	pause := func() (*Result, error) {
		c.Store.Checkpoint(c.Dir, st)
		return nil, ErrStopped
	}
	// Hop 1 reads the owner's own list; hop h reads the lists of the people
	// at distance h-1 who pass the bar. Ranking out to MaxHop needs lists
	// out to MaxHop-1.
	full := false
	for ; st.Hop <= c.Params.MaxHop && !full; st.Hop, st.Next, st.Last = st.Hop+1, 0, "" {
		readers, err := c.readers(st.Hop)
		if err != nil {
			return nil, err
		}
		// The reader list is built again on resume, and lists read earlier
		// in this hop can change it (a mute moves a score across the bar),
		// so the place is the last pubkey read, not an index: go on at the
		// first reader after it (readers are sorted).
		st.Next = sort.SearchStrings(readers, st.Last)
		if st.Next < len(readers) && readers[st.Next] == st.Last && st.Last != "" {
			st.Next++
		}
		lastSave := c.now()
		for ; st.Next < len(readers); st.Next++ {
			if !c.Wait(ctx) || ctx.Err() != nil {
				return pause()
			}
			pk := readers[st.Next]
			// A full pass reads every list again (a resumed one starts at
			// the checkpoint's place); a refresh asks only for newer ones.
			have, stored := c.Store.CreatedAt(pk)
			since := int64(0)
			if stored && refresh {
				since = have + 1
			}
			l, found, err := c.Fetch.Fetch(ctx, pk, since)
			if err == nil && found {
				limit := c.now().Add(maxSkew).Unix()
				l.FollowsAt, l.MutesAt = min(l.FollowsAt, limit), min(l.MutesAt, limit)
				// Kind by kind: a stale copy of one kind never replaces a
				// newer stored one, even when the other kind is new.
				_, err = c.Store.PutList(pk, l)
			}
			if errors.Is(err, ErrFull) {
				full = true // keep what we have and rank it
				break
			}
			st.Last = pk
			if c.Progress != nil {
				c.Progress(st.Hop, st.Next+1, len(readers))
			}
			if (st.Next+1)%checkpointEvery == 0 || c.now().Sub(lastSave) > 30*time.Second {
				c.Store.Checkpoint(c.Dir, st)
				lastSave = c.now()
			}
			if c.Pace > 0 {
				select {
				case <-ctx.Done():
					return pause() // this list is read; the place is st.Last
				case <-time.After(c.Pace):
				}
			}
		}
		c.Store.Sync()
	}
	res, err := c.rank()
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
		st.RefreshAt = c.now().Unix()
	default:
		st.FullAt = c.now().Unix()
	}
	c.Store.Compact()
	return res, c.Store.Checkpoint(c.Dir, st)
}

func (c *Crawler) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Crawler) rank() (*Result, error) {
	g, err := c.Store.Graph()
	if err != nil {
		return nil, err
	}
	var blocks []string
	if c.OwnerBlocks != nil {
		blocks = c.OwnerBlocks()
	}
	return Rank(g, c.Owner, blocks, c.Params)
}

// readers is who has their list read at hop h, in a fixed order so the
// checkpoint's place means the same thing after a restart.
func (c *Crawler) readers(h int) ([]string, error) {
	if h == 1 {
		return []string{c.Owner}, nil
	}
	if _, stored := c.Store.CreatedAt(c.Owner); !stored {
		return nil, nil // no owner list: nobody to walk out to
	}
	res, err := c.rank()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, p := range res.People() {
		if p.Hop == h-1 && res.Passes(p.Pubkey, c.Bar) {
			out = append(out, p.Pubkey)
		}
	}
	sort.Strings(out)
	return out, nil
}

// ResultFile is wot_rank_<account>.json: what the phones read. Never
// published.
type ResultFile struct {
	Account string   `json:"account"`
	BuiltAt int64    `json:"builtAt"`
	Version int      `json:"version"`
	Params  Params   `json:"params"`
	MaxHop  int      `json:"maxHop"`
	People  [][3]any `json:"people"` // [pubkey, score 0-100 to 0.1, hop]
}

// ResultPath is the result's file for account in dir.
func ResultPath(dir, account string) string {
	return filepath.Join(dir, "wot_rank_"+account+".json")
}

func writeResult(dir string, r *Result, now time.Time) error {
	f := ResultFile{Account: r.Owner, BuiltAt: now.Unix(), Version: 1, Params: r.Params, MaxHop: r.Params.MaxHop}
	for _, p := range r.People() {
		s := math.Round(p.Score*10) / 10
		if s == 0 && p.Hop > 1 {
			continue // nobody trusted vouches for them: not worth the bytes
		}
		f.People = append(f.People, [3]any{p.Pubkey, s, p.Hop})
	}
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
