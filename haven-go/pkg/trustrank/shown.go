package trustrank

import "math"

// The shown score: what the apps put on screen and what the user's slider
// moves. The rank's own score (Score, Person.Score) spans three orders of
// magnitude (0.02 to ~30 on Logen's 2026-11-22 map), so it is shown on a log
// scale: every ×10 in trust adds the same number of points.
//
// The anchors are fixed, not fitted to each map, so a number means the same
// thing for everyone and from one day to the next:
//   - rank 0.2 shows as 20: under it was all the spam in the 2026-11-22
//     sample (scams, porn, bots: people that trusted accounts muted);
//   - rank 30 shows as 100: the owner's own follows (~29).
//
// Measured bands on that map (RESEARCH/NV_WOT_TRUST_RANK_2026_11_20.md §10):
// 0-20 spam, 20-45 empty or abandoned accounts, 45-57 thin but real,
// 57-70 real, 70-90 heavily vouched, 90-100 the owner's own web.
const (
	shownLowRank, shownLow   = 0.2, 20.0
	shownHighRank, shownHigh = 30.0, 100.0
)

var shownPerDecade = (shownHigh - shownLow) / (math.Log10(shownHighRank) - math.Log10(shownLowRank))

// DefaultViewBar is where the user's slider starts (shown scale): about
// 3,000 hop-3 people on Logen's map, real accounts, no spam in the sample.
const DefaultViewBar = 55.0

// Shown maps a rank score (0-100, as Score returns) to the shown 0-100 scale.
// It keeps the order: a higher rank always shows higher or equal.
// A NaN rank shows as 0, so it can never reach the file (json.Marshal
// refuses NaN and the whole result write would be lost).
func Shown(rank float64) float64 {
	if rank <= 0 || math.IsNaN(rank) {
		return 0
	}
	s := shownLow + shownPerDecade*(math.Log10(rank)-math.Log10(shownLowRank))
	return math.Max(0, math.Min(100, s))
}

// RankFor is Shown's inverse: the rank score a shown value stands for. For a
// bar on the shown scale, compare rank scores against RankFor(bar).
func RankFor(shown float64) float64 {
	if shown <= 0 {
		return 0
	}
	return math.Pow(10, math.Log10(shownLowRank)+(shown-shownLow)/shownPerDecade)
}

// ShownRounded is Shown rounded to 0.1: the number written to the result
// file. It is the one truth for the slider: the file's value and
// PassesShown both use it, so a phone filtering on the file and a server
// calling PassesShown agree on the person at the slider's edge.
func ShownRounded(rank float64) float64 {
	return math.Round(Shown(rank)*10) / 10
}

// PassesShown is Passes with the bar on the shown scale (the slider's value),
// compared against ShownRounded, the same number the result file holds.
func (r *Result) PassesShown(pk string, bar float64) bool {
	i, ok := r.g.index[pk]
	if !ok || r.hop[i] < 0 || r.ownerMuted[i] {
		return false
	}
	return r.hop[i] == 1 || ShownRounded(r.trust[i]*100) >= bar
}
