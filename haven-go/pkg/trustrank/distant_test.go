package trustrank

import (
	"encoding/json"
	"strings"
	"testing"
)

func distantHex(c byte) string { return strings.Repeat(string(c), 64) }

// Distant: hop 3 and out only, highest shown first, ties by key, the
// account itself and skipped people left out, cut at n.
func TestDistantPicksTopHop3Plus(t *testing.T) {
	owner := distantHex('0')
	f := ResultFile{Account: owner, People: [][3]any{
		{distantHex('1'), 99.0, 1}, {distantHex('2'), 98.0, 2},
		{distantHex('3'), 60.0, 3}, {distantHex('4'), 80.0, 4},
		{distantHex('6'), 70.0, 3}, {distantHex('5'), 70.0, 5},
		{distantHex('7'), 90.0, 3}, {owner, 100.0, 3},
		{"not hex", 95.0, 3},
	}}
	// Through JSON, as ReadResult hands it back.
	raw, _ := json.Marshal(f)
	var g ResultFile
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	got := g.Distant(4, map[string]bool{distantHex('7'): true})
	want := []string{distantHex('4'), distantHex('5'), distantHex('6'), distantHex('3')}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v\nwant %v", got, want)
	}
	if got := g.Distant(2, nil); len(got) != 2 || got[0] != distantHex('7') {
		t.Fatalf("cut at 2: %v", got)
	}
}
