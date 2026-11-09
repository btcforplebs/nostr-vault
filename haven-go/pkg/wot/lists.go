package wot

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// listsFile keeps the follows' own follow lists between rebuilds, so a rebuild
// asks relays only for what changed (since the last complete fetch) and for
// follows it has no list for yet. Before it, every rebuild, including the one
// after each follow or unfollow, downloaded every follow's list again: about
// 12 MB per 250 follows and 224 MiB allocated at 859 follows.
const listsFile = "wot_lists.json"

// listsVersion: bump when the stored shape or its meaning changes; another
// version is ignored and the next rebuild is a full one.
const listsVersion = 1

// fullListsEvery is how often a rebuild asks for every follow's list anyway,
// whatever is stored: it catches a list a relay only got after the since
// window had passed, or one the author deleted.
const fullListsEvery = 7 * 24 * time.Hour

// sinceSlack widens the since window: a list's created_at is the author's
// clock, and a relay can receive it a little after it was signed.
const sinceSlack = int64(time.Hour / time.Second)

// followList is one follow's list as the rebuild counts it: its time and its
// p tags in order (repeats kept, so counts match a fresh download).
type followList struct {
	at       int64
	contacts []string
}

func listFromEvent(ev *nostr.Event) followList {
	l := followList{at: int64(ev.CreatedAt)}
	for tag := range ev.Tags.FindAll("p") {
		if len(tag) > 1 {
			l.contacts = append(l.contacts, tag[1])
		}
	}
	return l
}

// storedLists is the file's shape. Contacts are indexes into Names, which
// keeps a big web's file to a few MB instead of repeating every pubkey once
// per follow who follows it.
type storedLists struct {
	Version int `json:"version"`
	// Since is the start of the last rebuild whose every list fetch was
	// complete; 0 means the next rebuild must be a full one.
	Since int64 `json:"since"`
	// FullAt is the start of the last complete full fetch.
	FullAt int64                 `json:"fullAt"`
	Names  []string              `json:"names"`
	Lists  map[string]storedList `json:"lists"`
}

type storedList struct {
	At int64 `json:"at"`
	P  []int `json:"p"`
}

func (wt *SimpleInMemory) listsPath() string {
	return filepath.Join(filepath.Dir(wt.CachePath), listsFile)
}

// loadLists reads the stored follows' lists. ok is false when there are
// none to build on (no file, unreadable, another version).
func (wt *SimpleInMemory) loadLists() (lists map[string]followList, since, fullAt int64, ok bool) {
	if wt.CachePath == "" {
		return nil, 0, 0, false
	}
	data, err := os.ReadFile(wt.listsPath())
	if err != nil {
		return nil, 0, 0, false
	}
	var s storedLists
	if err := json.Unmarshal(data, &s); err != nil {
		slog.Warn("🚫 Failed to parse WoT lists; next rebuild fetches them all", "error", err)
		return nil, 0, 0, false
	}
	if s.Version != listsVersion {
		return nil, 0, 0, false
	}
	lists = make(map[string]followList, len(s.Lists))
	for pk, l := range s.Lists {
		fl := followList{at: l.At, contacts: make([]string, 0, len(l.P))}
		for _, i := range l.P {
			if i < 0 || i >= len(s.Names) {
				slog.Warn("🚫 WoT lists file is damaged; next rebuild fetches them all")
				return nil, 0, 0, false
			}
			fl.contacts = append(fl.contacts, s.Names[i])
		}
		lists[pk] = fl
	}
	return lists, s.Since, s.FullAt, true
}

// saveLists swaps the lists file in whole, like the cache, so a crash or a
// reader mid-write never sees half of it. nil lists removes the file.
func (wt *SimpleInMemory) saveLists(lists map[string]followList, since, fullAt int64) {
	if wt.CachePath == "" {
		return
	}
	path := wt.listsPath()
	if lists == nil {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			slog.Error("🚫 Failed to remove WoT lists", "error", err)
		}
		return
	}
	s := storedLists{Version: listsVersion, Since: since, FullAt: fullAt, Lists: make(map[string]storedList, len(lists))}
	index := make(map[string]int)
	for pk, l := range lists {
		p := make([]int, len(l.contacts))
		for j, c := range l.contacts {
			i, ok := index[c]
			if !ok {
				i = len(s.Names)
				index[c] = i
				s.Names = append(s.Names, c)
			}
			p[j] = i
		}
		s.Lists[pk] = storedList{At: l.at, P: p}
	}
	data, err := json.Marshal(s)
	if err != nil {
		slog.Error("🚫 Failed to marshal WoT lists", "error", err)
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		slog.Error("🚫 Failed to write WoT lists", "error", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		slog.Error("🚫 Failed to save WoT lists", "error", err)
		_ = os.Remove(tmp)
	}
}
