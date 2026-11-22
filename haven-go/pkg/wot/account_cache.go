package wot

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// accountCacheVersion: bump when a fix changes what an account's web holds,
// so files written by the older code are rebuilt. It starts one above the
// pooled wotCacheVersion (4), whose shape these files share.
const accountCacheVersion = 5

// Each account's web is saved beside the pooled wot_cache.json, under the
// account's hex pubkey: wot_cache_<hex>.json and, at level 3,
// wot_links_<hex>.json (same shape as wot_links.json).
const (
	accountCachePrefix = "wot_cache_"
	accountLinksPrefix = "wot_links_"
)

// accountCache is wot_cache_<hex>.json. Pubkeys is everyone the account lets
// in (its own accounts on this device, its follows, its second layer), so an
// app can read it the way it reads wot_cache.json.
type accountCache struct {
	Version      int             `json:"version"`
	Depth        int             `json:"depth"`
	MinFollowers int             `json:"min_followers"`
	Timestamp    int64           `json:"timestamp"`
	Follows      []string        `json:"follows,omitempty"`
	Pubkeys      map[string]bool `json:"pubkeys"`
	Vouches      map[string]int  `json:"vouches,omitempty"`
}

// storedAccountWeb is the part of the file a start reads back: Pubkeys is
// follows + vouches + own accounts again, so it is skipped.
type storedAccountWeb struct {
	Version      int            `json:"version"`
	Depth        int            `json:"depth"`
	MinFollowers int            `json:"min_followers"`
	Timestamp    int64          `json:"timestamp"`
	Follows      []string       `json:"follows"`
	Vouches      map[string]int `json:"vouches"`
}

func (wt *SimpleInMemory) accountFilePath(prefix, owner string) string {
	return filepath.Join(filepath.Dir(wt.CachePath), prefix+owner+".json")
}

// writeWhole swaps a file in whole, so a crash or a reader mid-write never
// sees half of it.
func writeWhole(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// saveAccountWeb writes owner's web file and, at level 3, its links file. A
// nil links removes the links file (levels 1 and 2 never see the follows'
// lists).
func (wt *SimpleInMemory) saveAccountWeb(owner string, web *accountWeb, links map[string][]int) {
	if wt.CachePath == "" {
		return
	}
	cache := accountCache{
		Version:      accountCacheVersion,
		Depth:        web.reach.Depth,
		MinFollowers: web.reach.MinFollowers,
		Timestamp:    web.builtAt,
		Follows:      web.follows,
		Pubkeys:      make(map[string]bool, len(wt.WhitelistedPubKeys)+len(web.follows)+len(web.vouches)),
		Vouches:      web.vouches,
	}
	for pk := range wt.WhitelistedPubKeys {
		cache.Pubkeys[pk] = true
	}
	for _, pk := range web.follows {
		cache.Pubkeys[pk] = true
	}
	for pk := range web.vouches {
		cache.Pubkeys[pk] = true
	}
	data, err := json.Marshal(cache)
	if err == nil {
		err = writeWhole(wt.accountFilePath(accountCachePrefix, owner), data)
	}
	if err != nil {
		slog.Error("🚫 Failed to save an account's web", "error", err)
		return
	}

	linksPath := wt.accountFilePath(accountLinksPrefix, owner)
	if links == nil {
		if err := os.Remove(linksPath); err != nil && !os.IsNotExist(err) {
			slog.Error("🚫 Failed to remove an account's WoT links", "error", err)
		}
		return
	}
	data, err = json.Marshal(wotLinks{Timestamp: time.Now().Unix(), Follows: web.follows, Links: links})
	if err == nil {
		err = writeWhole(linksPath, data)
	}
	if err != nil {
		slog.Error("🚫 Failed to save an account's WoT links", "error", err)
	}
}

// loadAccountWebs reads back each account's saved web. A file that is
// missing, unreadable, from another version, or built at another level or
// bar than the account has now is skipped: HasFor answers from the pooled
// web for that account until MissingFiles' rebuild replaces it.
func (wt *SimpleInMemory) loadAccountWebs() {
	if wt.CachePath == "" {
		return
	}
	webs := make(accountWebs, len(wt.WhitelistedPubKeys))
	for owner := range wt.WhitelistedPubKeys {
		data, err := os.ReadFile(wt.accountFilePath(accountCachePrefix, owner))
		if err != nil {
			continue
		}
		var stored storedAccountWeb
		if err := json.Unmarshal(data, &stored); err != nil {
			slog.Warn("🚫 Failed to parse an account's web", "error", err)
			continue
		}
		reach := wt.reachOf(owner)
		if stored.Version != accountCacheVersion || stored.Depth != reach.Depth || stored.MinFollowers != reach.MinFollowers {
			continue
		}
		slices.Sort(stored.Follows)
		webs[owner] = &accountWeb{reach: reach, follows: stored.Follows, vouches: stored.Vouches, builtAt: stored.Timestamp}
	}
	if len(webs) > 0 {
		wt.webs.Store(&webs)
	}
}

// MissingFiles reports a saved graph the next rebuild would add files to:
// MissingLinks, or an account with no web of its own loaded (a cache from
// before the per-account files, a new account, or an account whose Follow
// Distance changed). The pooled graph is still good, so callers serve the
// cache and refresh in the background.
func (wt *SimpleInMemory) MissingFiles() bool {
	if wt.MissingLinks() {
		return true
	}
	if wt.WotDepth == 0 || wt.CachePath == "" {
		return false
	}
	webs := wt.webs.Load()
	for owner := range wt.WhitelistedPubKeys {
		if webs == nil || (*webs)[owner] == nil {
			return true
		}
	}
	return false
}

// removeOtherAccountFiles deletes the web and links files of anyone keep
// does not name: an account removed from this device leaves no file naming
// its follows behind.
func (wt *SimpleInMemory) removeOtherAccountFiles(keep func(owner string) bool) {
	if wt.CachePath == "" {
		return
	}
	dir := filepath.Dir(wt.CachePath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		for _, prefix := range []string{accountCachePrefix, accountLinksPrefix} {
			owner, ok := strings.CutPrefix(name, prefix)
			if !ok {
				continue
			}
			owner, ok = strings.CutSuffix(owner, ".json")
			// Only names this code writes: a 64-character hex pubkey.
			if !ok || len(owner) != 64 || keep(owner) {
				continue
			}
			if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
				slog.Error("🚫 Failed to remove a removed account's web", "error", err)
			}
		}
	}
}
