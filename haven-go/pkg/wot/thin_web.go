package wot

import (
	"cmp"
	"slices"
)

// newAccountWebCap is how many people a new account's web takes from its
// follows' lists. Like the globe's sample of someone else's web, it is
// enough to fill Global without naming everyone a big account follows.
const newAccountWebCap = 1000

// newAccountWeb picks the second layer for an owner who follows fewer people
// than the bar asks for. Nobody can be followed by more of your follows than
// you have, so with the default bar of 3 an owner with one or two follows got
// a web of just themselves and those follows, and Global stayed thin until
// they followed a third. Until then the web is the people their follows
// follow, most vouched first, up to newAccountWebCap. counts is each
// person's follower count from the lists fetched; anyone already in web is
// skipped. Returns nil once the owner follows enough people for the bar.
func newAccountWeb(counts map[string]int, web map[string]bool, follows, bar int) []string {
	if follows >= bar {
		return nil
	}
	var people []string
	for pk := range counts {
		if !web[pk] {
			people = append(people, pk)
		}
	}
	slices.SortFunc(people, func(a, b string) int {
		if n := cmp.Compare(counts[b], counts[a]); n != 0 {
			return n
		}
		return cmp.Compare(a, b)
	})
	return people[:min(len(people), newAccountWebCap)]
}
