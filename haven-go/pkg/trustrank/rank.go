// Package trustrank scores people 0-100 from one owner's point of view,
// GrapeRank style: a follow is a rating of 1, a mute a rating of 0, and each
// rating counts as much as its rater is trusted. The owner's trust is fixed;
// everyone else's comes only from ratings by people the owner already trusts,
// so accounts that follow each other gain nothing unless a trusted person
// follows them.
//
// A score is personal: it is computed on the owner's own server from the
// owner's own network and is never published or sent to anyone.
//
// The package is pure: no network, no disk. The crawler feeds it lists.
package trustrank

import "errors"

// Params are the rank's weights. The defaults are working numbers until
// David Strayhorn (GrapeRank) sets them.
type Params struct {
	// How much one follow counts, before the rater's own trust.
	FollowConfidence float64
	// How much one mute counts. A mute rates 0, so it pulls the average down.
	MuteConfidence float64
	// How much the owner's own follows count. The owner is fully trusted, so
	// this sets the trust their follows start from.
	OwnerFollowConfidence float64
	// Trust fades by this factor for every rating not made by the owner.
	Attenuation float64
	// How fast certainty grows with the ratings' total weight, 0-1. Higher
	// needs more ratings for the same certainty.
	Rigor float64
	// Stop when no score moves by more than this (on the 0-1 scale).
	Epsilon float64
	// Stop after this many rounds whatever the change.
	MaxRounds int
	// People further than this many follow hops from the owner are left out.
	MaxHop int
}

// DefaultParams are the working weights from the 2026-11-20 measurement
// (RESEARCH/NV_WOT_TRUST_RANK_2026_11_20.md), stopping at hop 3.
func DefaultParams() Params {
	return Params{
		FollowConfidence:      0.03,
		MuteConfidence:        0.5,
		OwnerFollowConfidence: 0.5,
		Attenuation:           0.85,
		Rigor:                 0.5,
		Epsilon:               1e-5,
		MaxRounds:             100,
		MaxHop:                3,
	}
}

func (p Params) validate() error {
	in01 := func(v float64) bool { return v > 0 && v <= 1 }
	if !in01(p.FollowConfidence) || !in01(p.MuteConfidence) || !in01(p.OwnerFollowConfidence) ||
		!in01(p.Attenuation) || p.Rigor <= 0 || p.Rigor >= 1 {
		return errors.New("trustrank: confidences and attenuation must be in (0,1], rigor in (0,1)")
	}
	if p.Epsilon <= 0 || p.MaxRounds < 1 || p.MaxHop < 1 {
		return errors.New("trustrank: epsilon, max rounds and max hop must be positive")
	}
	return nil
}

// Graph holds the follow and mute lists the crawler has read. Each pubkey is
// stored once; lists are indexes into that table.
type Graph struct {
	keys    []string
	index   map[string]int32
	follows [][]int32
	mutes   [][]int32
}

// NewGraph returns an empty graph.
func NewGraph() *Graph { return &Graph{index: map[string]int32{}} }

func (g *Graph) id(pk string) int32 {
	if i, ok := g.index[pk]; ok {
		return i
	}
	i := int32(len(g.keys))
	g.keys = append(g.keys, pk)
	g.index[pk] = i
	g.follows = append(g.follows, nil)
	g.mutes = append(g.mutes, nil)
	return i
}

// SetList records rater's follows and mutes, replacing any earlier list.
// Self-ratings and repeats are dropped; a person both followed and muted
// counts as muted.
func (g *Graph) SetList(rater string, follows, mutes []string) {
	r := g.id(rater)
	muted := map[int32]bool{}
	var ms []int32
	for _, pk := range mutes {
		t := g.id(pk)
		if t != r && !muted[t] {
			muted[t] = true
			ms = append(ms, t)
		}
	}
	seen := map[int32]bool{}
	var fs []int32
	for _, pk := range follows {
		t := g.id(pk)
		if t != r && !muted[t] && !seen[t] {
			seen[t] = true
			fs = append(fs, t)
		}
	}
	g.follows[r], g.mutes[r] = fs, ms
}

// Size is the number of distinct pubkeys seen.
func (g *Graph) Size() int { return len(g.keys) }
