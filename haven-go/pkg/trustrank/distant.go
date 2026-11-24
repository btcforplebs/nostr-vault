package trustrank

import "sort"

// Distant connections (discovery engine, design B): the people at hop 3 or
// further out. A Haven fetches their recent posts, and an owner's devices
// get those posts from it over the mesh. Both sides pick the same people
// from the same result, so a device can check what it is given.

// DistantMax: how many distant connections' posts a Haven fetches per
// account. On Logen's 2026-11-23 map the top 500 run from 84 down to 63.6
// shown, and about a dozen of them post in a week.
const DistantMax = 500

// DistantHop: the first ring that counts as distant ("Distant connections"
// in the apps). Hop 2 is the account's circle.
const DistantHop = 3

// Distant is the top n people at DistantHop or further in f, highest shown
// score first (ties by pubkey, so every reader gets the same list), leaving
// out the account itself and anyone in skip. f must have been through JSON
// (ReadResult, CheckHandoff).
func (f ResultFile) Distant(n int, skip map[string]bool) []string {
	type pick struct {
		pk    string
		shown float64
	}
	var all []pick
	for _, r := range f.People {
		pk, shown, hop, ok := row(r)
		if !ok || hop < DistantHop || pk == f.Account || skip[pk] {
			continue
		}
		all = append(all, pick{pk, shown})
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].shown != all[j].shown {
			return all[i].shown > all[j].shown
		}
		return all[i].pk < all[j].pk
	})
	if n >= 0 && len(all) > n {
		all = all[:n]
	}
	out := make([]string, len(all))
	for i, p := range all {
		out[i] = p.pk
	}
	return out
}
