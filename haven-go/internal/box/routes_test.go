package box

import (
	"sort"
	"strings"
	"testing"
)

// TestRoutesRegistered pins the box API's route set, so a split or a new
// routes_*.go file cannot drop or rename a route without this failing.
func TestRoutesRegistered(t *testing.T) {
	want := []string{
		"GET /api/box/devices",
		"GET /api/box/status",
		"GET /api/box/storage",
		"POST /api/box/move",
		"POST /api/box/update",
	}
	var got []string
	for r := range boxRoutes {
		got = append(got, r)
	}
	sort.Strings(got)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("routes:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}
