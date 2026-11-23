package trustrank

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSummarizeCountsRingsAndDistantScores(t *testing.T) {
	owner := strings.Repeat("a", 64)
	pk := func(c string) string { return strings.Repeat(c, 64) }
	f := ResultFile{Account: owner, BuiltAt: 7, MaxHop: 4, ViewBar: 55,
		People: [][3]any{{pk("1"), 12.0, 1}, {pk("2"), 80.0, 2}, {pk("3"), 60.4, 3}, {pk("4"), 55.0, 3},
			{pk("5"), 54.9, 4}, {pk("6"), 100.0, 4}, {owner, 99.0, 3}, {"bad", 70.0, 3}}}
	raw, _ := json.Marshal(f)
	var back ResultFile
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	s := back.Summarize()
	if s.BuiltAt != 7 || s.People != 7 || s.MaxHop != 4 || s.ViewBar != 55 {
		t.Fatalf("header: %+v", s)
	}
	if len(s.Rings) != 4 || s.Rings[0] != 1 || s.Rings[1] != 1 || s.Rings[2] != 3 || s.Rings[3] != 2 {
		t.Fatalf("rings: %v", s.Rings)
	}
	// The owner and ring 1-2 are never distant; 60.4 counts at 60, 54.9 at 54.
	if s.DistantByShown[60] != 1 || s.DistantByShown[55] != 1 || s.DistantByShown[54] != 1 || s.DistantByShown[100] != 1 || s.DistantByShown[99] != 0 {
		t.Fatalf("buckets wrong")
	}
	if n := s.DistantAtBar(55); n != 3 {
		t.Fatalf("at 55: %d", n)
	}
	if n := s.DistantAtBar(54.5); n != 3 {
		t.Fatalf("at 54.5 (54.9 rounds down to 54): %d", n)
	}
	if n := s.DistantAtBar(0); n != 4 {
		t.Fatalf("at 0: %d", n)
	}
}
