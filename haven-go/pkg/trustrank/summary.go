package trustrank

// Summary is what a status screen shows of a result file: how many people
// were ranked, how far out, and how many distant connections (ring
// DistantHop and past) show at each whole score, so a screen can count the
// ones at or over its own slider bar without the rows.
type Summary struct {
	BuiltAt int64 `json:"builtAt"`
	People  int   `json:"people"`
	MaxHop  int   `json:"maxHop"`
	// Rings[h-1]: people in ring h.
	Rings []int `json:"rings"`
	// DistantByShown[s]: distant connections whose shown score rounds down
	// to s (0-100). The owner is never counted.
	DistantByShown [101]int `json:"distantByShown"`
	ViewBar        float64  `json:"viewBar"`
	// Floor: set when this is a device's trimmed copy (handoff.go).
	Floor float64 `json:"floor,omitempty"`
}

// Summarize counts f's rows. f must have been through JSON (ReadResult).
func (f ResultFile) Summarize() Summary {
	s := Summary{BuiltAt: f.BuiltAt, MaxHop: f.MaxHop, ViewBar: f.ViewBar, Floor: f.Floor}
	for _, r := range f.People {
		pk, shown, hop, ok := row(r)
		if !ok || hop < 1 || hop > CeilingHop {
			continue
		}
		s.People++
		for len(s.Rings) < hop {
			s.Rings = append(s.Rings, 0)
		}
		s.Rings[hop-1]++
		if hop >= DistantHop && pk != f.Account {
			s.DistantByShown[min(max(int(shown), 0), 100)]++
		}
	}
	return s
}

// DistantAtBar: distant connections that show at or over bar.
func (s Summary) DistantAtBar(bar float64) int {
	n := 0
	for score := 100; score >= 0 && float64(score) >= bar; score-- {
		n += s.DistantByShown[score]
	}
	return n
}
