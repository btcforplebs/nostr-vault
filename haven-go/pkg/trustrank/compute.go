package trustrank

import (
	"errors"
	"math"
	"sort"
)

// Result is one owner's rank. Scores are 0-100.
type Result struct {
	Owner      string
	Params     Params
	Rounds     int
	g          *Graph
	owner      int32
	hop        []int8    // -1: further than MaxHop or unreachable
	trust      []float64 // 0-1, the owner is 1
	ownerMuted map[int32]bool
}

// Rank scores everyone within Params.MaxHop follow hops of owner. ownerBlocks
// are the owner's public and private mutes and blocks: those people score 0
// and their own lists count for nothing, whatever anyone else says.
func Rank(g *Graph, owner string, ownerBlocks []string, p Params) (*Result, error) {
	if err := p.validate(); err != nil {
		return nil, err
	}
	o, ok := g.index[owner]
	if !ok || !g.listed[o] {
		return nil, errors.New("trustrank: the owner's own list is not in the graph")
	}
	res := &Result{Owner: owner, Params: p, g: g, owner: o, ownerMuted: map[int32]bool{}}
	for _, pk := range ownerBlocks {
		if i, ok := g.index[pk]; ok && i != o {
			res.ownerMuted[i] = true
		}
	}
	for _, i := range g.mutes[o] {
		res.ownerMuted[i] = true
	}
	res.hops()
	res.iterate()
	return res, nil
}

// hops sets each person's true follow distance from the owner. Owner-muted
// people are not walked through.
func (r *Result) hops() {
	n := len(r.g.keys)
	r.hop = make([]int8, n)
	for i := range r.hop {
		r.hop[i] = -1
	}
	r.hop[r.owner] = 0
	frontier := []int32{r.owner}
	for d := 1; d <= r.Params.MaxHop && len(frontier) > 0; d++ {
		var next []int32
		for _, u := range frontier {
			if r.ownerMuted[u] {
				continue
			}
			for _, v := range r.g.follows[u] {
				if r.hop[v] == -1 {
					r.hop[v] = int8(d)
					next = append(next, v)
				}
			}
		}
		frontier = next
	}
}

// vouches reports whether u's follow of v counts. Trust flows outward only:
// a follow counts when the rater is nearer the owner than the person
// followed. People who follow each other at the same distance, or back
// toward the owner, add nothing, so a ring that one trusted person follows
// cannot lift itself. Mutes count from any trusted rater: a mute can only
// lower a score (the certainty term grows slower than the weight).
func (r *Result) vouches(u, v int32) bool {
	return r.hop[u] >= 0 && r.hop[v] > r.hop[u]
}

// weight is how much rater u's rating of anyone counts, given trust t.
func (r *Result) weight(u int32, t []float64, follow bool) float64 {
	if u == r.owner {
		if follow {
			return r.Params.OwnerFollowConfidence
		}
		return 0 // the owner's mutes are absolute, not a rating
	}
	c := r.Params.FollowConfidence
	if !follow {
		c = r.Params.MuteConfidence
	}
	return t[u] * c * r.Params.Attenuation
}

func (r *Result) iterate() {
	n := len(r.g.keys)
	trust := make([]float64, n)
	trust[r.owner] = 1
	sumW := make([]float64, n)
	sumWR := make([]float64, n)
	k := -math.Log(r.Params.Rigor)
	for round := 1; round <= r.Params.MaxRounds; round++ {
		for i := range sumW {
			sumW[i], sumWR[i] = 0, 0
		}
		for u := int32(0); int(u) < n; u++ {
			if r.hop[u] < 0 || r.ownerMuted[u] || (u != r.owner && trust[u] == 0) {
				continue
			}
			wf := r.weight(u, trust, true)
			for _, v := range r.g.follows[u] {
				if r.vouches(u, v) {
					sumW[v] += wf
					sumWR[v] += wf
				}
			}
			if wm := r.weight(u, trust, false); wm > 0 {
				for _, v := range r.g.mutes[u] {
					sumW[v] += wm
				}
			}
		}
		maxDelta := 0.0
		for v := 0; v < n; v++ {
			if int32(v) == r.owner {
				continue
			}
			next := 0.0
			if r.hop[v] > 0 && !r.ownerMuted[int32(v)] && sumW[v] > 0 {
				next = (sumWR[v] / sumW[v]) * (1 - math.Exp(-sumW[v]*k))
			}
			if d := math.Abs(next - trust[v]); d > maxDelta {
				maxDelta = d
			}
			trust[v] = next
		}
		r.Rounds = round
		if maxDelta < r.Params.Epsilon {
			break
		}
	}
	r.trust = trust
}

// Score is pk's 0-100 score and follow distance. ok is false for anyone not
// within MaxHop (they are not part of this owner's map at all).
func (r *Result) Score(pk string) (score float64, hop int, ok bool) {
	i, found := r.g.index[pk]
	if !found || r.hop[i] < 0 {
		return 0, 0, false
	}
	return r.trust[i] * 100, int(r.hop[i]), true
}

// Person is one row of the result.
type Person struct {
	Pubkey string
	Score  float64 // 0-100
	Hop    int
}

// People returns everyone in the map except the owner, best first, ties by
// nearer hop then pubkey, so the order is stable.
func (r *Result) People() []Person {
	var out []Person
	for i, pk := range r.g.keys {
		if int32(i) == r.owner || r.hop[i] < 0 {
			continue
		}
		out = append(out, Person{Pubkey: pk, Score: r.trust[i] * 100, Hop: int(r.hop[i])})
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Score != out[b].Score {
			return out[a].Score > out[b].Score
		}
		if out[a].Hop != out[b].Hop {
			return out[a].Hop < out[b].Hop
		}
		return out[a].Pubkey < out[b].Pubkey
	})
	return out
}

// Passes reports whether pk clears bar (0-100) and is not muted by the owner.
// The bar gates who gets in; it never removes anyone the owner follows.
func (r *Result) Passes(pk string, bar float64) bool {
	i, ok := r.g.index[pk]
	if !ok || r.hop[i] < 0 || r.ownerMuted[i] {
		return false
	}
	return r.hop[i] == 1 || r.trust[i]*100 >= bar
}

// Reason is one rater's part in a score, for "why?".
type Reason struct {
	Rater  string
	Muted  bool    // the rater mutes them (pulls the score down)
	Weight float64 // how much this rating counted
}

// Explain lists who rated pk, heaviest first, at most n. Only ratings that
// counted appear: raters the owner trusts, and for a follow only a rater
// nearer the owner (see vouches).
func (r *Result) Explain(pk string, n int) []Reason {
	v, ok := r.g.index[pk]
	if !ok || r.hop[v] < 0 {
		return nil
	}
	var out []Reason
	for u := int32(0); int(u) < len(r.g.keys); u++ {
		if r.hop[u] < 0 || r.ownerMuted[u] || (u != r.owner && r.trust[u] == 0) {
			continue
		}
		if r.vouches(u, v) && contains(r.g.follows[u], v) {
			out = append(out, Reason{Rater: r.g.keys[u], Weight: r.weight(u, r.trust, true)})
		} else if w := r.weight(u, r.trust, false); w > 0 && contains(r.g.mutes[u], v) {
			out = append(out, Reason{Rater: r.g.keys[u], Muted: true, Weight: w})
		}
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Weight != out[b].Weight {
			return out[a].Weight > out[b].Weight
		}
		return out[a].Rater < out[b].Rater
	})
	if n > 0 && len(out) > n {
		out = out[:n]
	}
	return out
}

func contains(list []int32, v int32) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
