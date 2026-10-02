// Package followers keeps a ledger of who follows the relay's owner(s).
//
// Nostr has no "follow" event: a follow is a p-tag inside the follower's
// kind-3 list, and relays keep only the newest copy of that list. So nothing
// on the network records when someone followed you, an unfollow is a newer
// list that simply no longer tags you, and a follower who republishes their
// list (bots do this constantly) looks brand new every time. The ledger turns
// that stream of list snapshots into durable follow state by remembering what
// it has already seen:
//
//   - New:       first time we see this pubkey's list tag the owner.
//   - Returning: the pubkey had unfollowed and its list tags the owner again.
//   - Refresh:   the pubkey already follows; a newer list still tags the owner.
//     Counted (churn), never announced.
//   - Existing:  the list predates the ledger, so the follow is old news.
//
// Unfollows can't arrive through a #p subscription; the caller sweeps known
// followers' latest lists and reports them through ObserveList too.
//
// Storage is a JSON file rewritten atomically by Flush. The ledger is small
// (one record per follower) and changes rarely, so a full rewrite is fine.
package followers

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/spf13/afero"
)

// Change is what a list observation did to the ledger.
type Change int

const (
	Ignored   Change = iota // stale/duplicate list, or not about the owner
	New                     // first follow we have ever seen from this pubkey
	Returning               // followed again after an unfollow
	Refresh                 // still following; list republished
	Existing                // follow predates the ledger
	Unfollow                // a newer list no longer tags the owner
)

func (c Change) String() string {
	return [...]string{"ignored", "new", "returning", "refresh", "existing", "unfollow"}[c]
}

// churnWindow is how far back list republishes are counted for churn.
const churnWindow = 24 * time.Hour

// maxVersions bounds the per-record churn history.
const maxVersions = 64

// Record is one follower of one owner.
type Record struct {
	Follower string `json:"follower"`
	// FirstSeen is our clock when we first saw this pubkey follow the owner.
	FirstSeen int64 `json:"first_seen"`
	// FollowedAt is our clock when the current follow began (first follow or
	// latest return). Equal to FirstSeen until they unfollow and come back.
	FollowedAt int64 `json:"followed_at"`
	// UnfollowedAt is our clock when we saw them drop the owner; 0 while following.
	UnfollowedAt int64 `json:"unfollowed_at,omitempty"`
	// Follows counts follow starts we witnessed (1 = never left).
	Follows int `json:"follows"`
	// Existing marks a follow that predates the ledger: not news.
	Existing bool `json:"existing,omitempty"`
	// ListAt is created_at of the newest list we have applied.
	ListAt int64 `json:"list_at"`
	// ListSize is the number of p-tags in that list.
	ListSize int `json:"list_size"`
	// Versions holds created_at of recent distinct lists, for churn.
	Versions []int64 `json:"versions,omitempty"`
}

// Following reports whether the record is a current follow.
func (r *Record) Following() bool { return r.UnfollowedAt == 0 }

// Churn is the number of distinct lists published within churnWindow of now.
func (r *Record) Churn(now time.Time) int {
	cutoff := now.Add(-churnWindow).Unix()
	n := 0
	for _, v := range r.Versions {
		if v >= cutoff {
			n++
		}
	}
	return n
}

type ownerBook struct {
	SeededAt int64 `json:"seeded_at"`
	// BackfilledAt is when a full backfill of existing followers finished;
	// 0 until one has, so an interrupted first run retries it.
	BackfilledAt int64              `json:"backfilled_at,omitempty"`
	Followers    map[string]*Record `json:"followers"`
}

type fileFormat struct {
	Version int                   `json:"version"`
	Owners  map[string]*ownerBook `json:"owners"`
	// LastSweepAt is when the last unfollow sweep finished. Persisted so a
	// relay that never stays up a full sweep interval (a phone) still sweeps.
	LastSweepAt int64 `json:"last_sweep_at,omitempty"`
}

// Ledger is safe for concurrent use.
type Ledger struct {
	mu        sync.Mutex
	fs        afero.Fs
	path      string
	owners    map[string]*ownerBook
	lastSweep int64
	dirty     bool
	now       func() time.Time
}

// Open loads the ledger at path (a missing file is an empty ledger). Each
// owner in owners that has no book yet is seeded now: lists created before
// this moment are recorded as Existing rather than New.
func Open(appfs afero.Fs, path string, owners []string) (*Ledger, error) {
	return open(appfs, path, owners, time.Now)
}

func open(appfs afero.Fs, path string, owners []string, now func() time.Time) (*Ledger, error) {
	l := &Ledger{fs: appfs, path: path, owners: map[string]*ownerBook{}, now: now}
	data, err := afero.ReadFile(appfs, path)
	switch {
	case err == nil:
		var f fileFormat
		if err := json.Unmarshal(data, &f); err != nil {
			// A corrupt ledger must not block the relay; start over seeded now.
			l.dirty = true
		} else if f.Owners != nil {
			l.owners = f.Owners
			l.lastSweep = f.LastSweepAt
		}
	case os.IsNotExist(err):
	default:
		return nil, fmt.Errorf("followers: read %s: %w", path, err)
	}
	seed := l.now().Unix()
	for _, o := range owners {
		if b := l.owners[o]; b == nil || b.Followers == nil {
			l.owners[o] = &ownerBook{SeededAt: seed, Followers: map[string]*Record{}}
			l.dirty = true
		}
	}
	return l, nil
}

// ObserveList applies one kind-3 list by follower, created at createdAt, to
// owner's book. tagsOwner says whether the list p-tags the owner; listSize is
// its p-tag count. Lists older than the newest one already applied are
// ignored, so out-of-order delivery from several relays is harmless.
func (l *Ledger) ObserveList(owner, follower string, createdAt int64, tagsOwner bool, listSize int) Change {
	if follower == owner {
		return Ignored
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.owners[owner]
	if b == nil {
		return Ignored
	}
	now := l.now().Unix()
	r := b.Followers[follower]

	if r == nil {
		if !tagsOwner {
			return Ignored // a stranger's list without us: nothing to track
		}
		r = &Record{Follower: follower, FirstSeen: now, FollowedAt: now, Follows: 1,
			ListAt: createdAt, ListSize: listSize, Versions: []int64{createdAt}}
		b.Followers[follower] = r
		l.dirty = true
		if createdAt < b.SeededAt {
			r.Existing = true
			return Existing
		}
		return New
	}

	if createdAt <= r.ListAt {
		return Ignored
	}
	r.ListAt = createdAt
	r.ListSize = listSize
	r.Versions = append(r.Versions, createdAt)
	if len(r.Versions) > maxVersions {
		r.Versions = r.Versions[len(r.Versions)-maxVersions:]
	}
	l.dirty = true

	switch {
	case tagsOwner && r.Following():
		return Refresh
	case tagsOwner:
		r.UnfollowedAt = 0
		r.FollowedAt = now
		r.Follows++
		r.Existing = false
		return Returning
	case r.Following():
		r.UnfollowedAt = now
		return Unfollow
	default:
		return Ignored // still not following; list changed for other reasons
	}
}

// NeedsBackfill lists the owners whose existing followers were never fully
// backfilled.
func (l *Ledger) NeedsBackfill() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for o, b := range l.owners {
		if b.BackfilledAt == 0 {
			out = append(out, o)
		}
	}
	sort.Strings(out)
	return out
}

// BeginBackfill re-seeds owners that have never completed a backfill, so a
// retry after an interrupted first run (days later, say) still treats lists
// made in between as old news rather than as new follows.
func (l *Ledger) BeginBackfill(owners []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now().Unix()
	for _, o := range owners {
		if b := l.owners[o]; b != nil && b.BackfilledAt == 0 {
			b.SeededAt = now
			l.dirty = true
		}
	}
}

// SweepDue reports whether the last unfollow sweep is at least every old.
func (l *Ledger) SweepDue(every time.Duration) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.now().Unix()-l.lastSweep >= int64(every/time.Second)
}

// MarkSwept records a finished unfollow sweep.
func (l *Ledger) MarkSwept() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lastSweep = l.now().Unix()
	l.dirty = true
}

// MarkBackfilled records a completed backfill for owners.
func (l *Ledger) MarkBackfilled(owners []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now().Unix()
	for _, o := range owners {
		if b := l.owners[o]; b != nil {
			b.BackfilledAt = now
			l.dirty = true
		}
	}
}

// SweepTargets returns the current followers of owner (pubkeys) worth
// re-reading for unfollows. Spam-tier followers are skipped: their lists are
// the largest to download and their unfollows are not news.
func (l *Ledger) SweepTargets(owner string) []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.owners[owner]
	if b == nil {
		return nil
	}
	now := l.now()
	out := make([]string, 0, len(b.Followers))
	for pk, r := range b.Followers {
		if r.Following() && Classify(r, false, now) != TierSpam {
			out = append(out, pk)
		}
	}
	sort.Strings(out)
	return out
}

// Tier sorts a follower into a trust bucket.
type Tier string

const (
	TierTrusted Tier = "trusted" // in the owner's web of trust
	TierOther   Tier = "other"   // outside it, but nothing spam-like
	TierSpam    Tier = "spam"    // follow-everyone or constant-republish lists
)

// Spam thresholds. A list this large is a follow-everything bot; a list
// republished this often in a day is a refollow bot.
const (
	SpamListSize = 5000
	SpamChurn24h = 20
)

// Classify places r in a tier. trusted reports web-of-trust membership.
func Classify(r *Record, trusted bool, now time.Time) Tier {
	if trusted {
		return TierTrusted
	}
	if r.ListSize >= SpamListSize || r.Churn(now) >= SpamChurn24h {
		return TierSpam
	}
	return TierOther
}

// Entry is one follower in a Snapshot.
type Entry struct {
	Pubkey       string `json:"pubkey"`
	Tier         Tier   `json:"tier"`
	Following    bool   `json:"following"`
	Existing     bool   `json:"existing"`
	FirstSeen    int64  `json:"first_seen"`
	FollowedAt   int64  `json:"followed_at"`
	UnfollowedAt int64  `json:"unfollowed_at,omitempty"`
	Follows      int    `json:"follows"`
	ListSize     int    `json:"list_size"`
	Churn24h     int    `json:"churn_24h"`
}

// Counts summarises current follows per tier, plus witnessed unfollows.
type Counts struct {
	Trusted    int `json:"trusted"`
	Others     int `json:"others"`
	Spam       int `json:"spam"`
	Unfollowed int `json:"unfollowed"`
}

// Snapshot is the app-facing view of one owner's followers.
type Snapshot struct {
	Owner     string  `json:"owner"`
	SeededAt  int64   `json:"seeded_at"`
	Counts    Counts  `json:"counts"`
	Followers []Entry `json:"followers"`
}

// Snapshot returns owner's followers, newest follow first. trusted is the
// web-of-trust check; it is called with the ledger unlocked.
func (l *Ledger) Snapshot(owner string, trusted func(string) bool) Snapshot {
	l.mu.Lock()
	b := l.owners[owner]
	if b == nil {
		l.mu.Unlock()
		return Snapshot{Owner: owner, Followers: []Entry{}}
	}
	recs := make([]Record, 0, len(b.Followers))
	for _, r := range b.Followers {
		c := *r
		c.Versions = append([]int64(nil), r.Versions...)
		recs = append(recs, c)
	}
	snap := Snapshot{Owner: owner, SeededAt: b.SeededAt}
	l.mu.Unlock()

	now := l.now()
	snap.Followers = make([]Entry, 0, len(recs))
	for i := range recs {
		r := &recs[i]
		tier := Classify(r, trusted(r.Follower), now)
		if r.Following() {
			switch tier {
			case TierTrusted:
				snap.Counts.Trusted++
			case TierOther:
				snap.Counts.Others++
			case TierSpam:
				snap.Counts.Spam++
			}
		} else {
			snap.Counts.Unfollowed++
		}
		snap.Followers = append(snap.Followers, Entry{
			Pubkey: r.Follower, Tier: tier, Following: r.Following(), Existing: r.Existing,
			FirstSeen: r.FirstSeen, FollowedAt: r.FollowedAt, UnfollowedAt: r.UnfollowedAt,
			Follows: r.Follows, ListSize: r.ListSize, Churn24h: r.Churn(now),
		})
	}
	sort.Slice(snap.Followers, func(i, j int) bool {
		a, b := snap.Followers[i], snap.Followers[j]
		if a.FollowedAt != b.FollowedAt {
			return a.FollowedAt > b.FollowedAt
		}
		return a.Pubkey < b.Pubkey
	})
	return snap
}

// Flush writes the ledger if anything changed since the last flush.
func (l *Ledger) Flush() error {
	l.mu.Lock()
	if !l.dirty {
		l.mu.Unlock()
		return nil
	}
	data, err := json.Marshal(fileFormat{Version: 1, Owners: l.owners, LastSweepAt: l.lastSweep})
	l.dirty = false
	l.mu.Unlock()
	if err != nil {
		return fmt.Errorf("followers: encode: %w", err)
	}
	tmp := l.path + ".tmp"
	if err := writeSynced(l.fs, tmp, data); err != nil {
		l.markDirty()
		return fmt.Errorf("followers: write %s: %w", tmp, err)
	}
	if err := l.fs.Rename(tmp, l.path); err != nil {
		l.markDirty()
		return fmt.Errorf("followers: rename %s: %w", tmp, err)
	}
	return nil
}

func (l *Ledger) markDirty() {
	l.mu.Lock()
	l.dirty = true
	l.mu.Unlock()
}

// writeSynced writes data and fsyncs before close, so the rename that
// follows can never publish an empty or torn file after a power loss.
func writeSynced(appfs afero.Fs, path string, data []byte) error {
	f, err := appfs.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
