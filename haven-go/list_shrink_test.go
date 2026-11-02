package main

import (
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

func listOf(kind int, items int, content string, extra ...nostr.Tag) *nostr.Event {
	tags := nostr.Tags{}
	tags = append(tags, extra...)
	for i := 0; i < items; i++ {
		tags = append(tags, nostr.Tag{"e", strings.Repeat("a", 63) + string(rune('a'+i%26))})
	}
	return &nostr.Event{Kind: kind, Tags: tags, Content: content}
}

// The shrink rule, case by case (RESEARCH/NV_LIST_PROTECTION_PLAN.md). The
// apps mirror this table.
func TestListShrankRule(t *testing.T) {
	big := strings.Repeat("x", 2000)
	cases := []struct {
		name       string
		prev, next *nostr.Event
		want       bool
	}{
		{"emptied", listOf(10003, 3, ""), listOf(10003, 0, ""), true},
		{"emptied a one-item list", listOf(10002, 1, ""), listOf(10002, 0, ""), true},
		{"fewer than half of 240", listOf(10003, 240, ""), listOf(10003, 100, ""), true},
		{"exactly half is an edit", listOf(10003, 20, ""), listOf(10003, 10, ""), false},
		{"small list edited down", listOf(10002, 4, ""), listOf(10002, 1, ""), false},
		{"nine to one is small", listOf(3, 9, ""), listOf(3, 1, ""), false},
		{"ten to four", listOf(3, 10, ""), listOf(3, 4, ""), true},
		{"a grow", listOf(3, 10, ""), listOf(3, 30, ""), false},
		{"empty to empty", listOf(3, 0, ""), listOf(3, 0, ""), false},
		{"private part wiped", listOf(10000, 2, big), listOf(10000, 2, ""), true},
		{"private part cut by more than half", listOf(10003, 2, big), listOf(10003, 2, big[:900]), true},
		{"private part edited", listOf(10003, 2, big), listOf(10003, 2, big[:1200]), false},
		{"small private part shortened", listOf(10003, 2, big[:400]), listOf(10003, 2, big[:100]), false},
		{"kind 3 content is not a private part", listOf(3, 5, big), listOf(3, 5, ""), false},
		{"profile emptied", profile(`{"name":"a","about":"b","picture":"c"}`), profile(`{}`), true},
		{"profile fields blanked", profile(`{"name":"a","about":"b"}`), profile(`{"name":"","about":""}`), true},
		{"profile edited", profile(`{"name":"a","about":"b"}`), profile(`{"name":"z"}`), false},
		{"title and d are not items", listOf(30003, 0, "", nostr.Tag{"d", "x"}, nostr.Tag{"title", "T"}), listOf(30003, 0, "", nostr.Tag{"d", "x"}), false},
	}
	for _, c := range cases {
		if got := listShrank(c.prev, c.next); got != c.want {
			t.Errorf("%s: listShrank = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestListItemCountSkipsMetadata(t *testing.T) {
	ev := listOf(30003, 3, "", nostr.Tag{"d", "reading"}, nostr.Tag{"title", "Reading"}, nostr.Tag{"client", "nv"})
	if got := listItemCount(ev); got != 3 {
		t.Fatalf("items = %d, want 3", got)
	}
}

func TestProtectedListKinds(t *testing.T) {
	for _, k := range []int{0, 3, 10000, 10002, 10003, 10050, 10063, 30000, 30003} {
		if !isProtectedListKind(k) {
			t.Errorf("kind %d should be protected", k)
		}
	}
	for _, k := range []int{1, 7, 30023, 10009} {
		if isProtectedListKind(k) {
			t.Errorf("kind %d should not be protected", k)
		}
	}
}

func profile(content string) *nostr.Event { return &nostr.Event{Kind: 0, Content: content} }

func TestProfileFieldCount(t *testing.T) {
	for content, want := range map[string]int{
		`{"name":"a","about":"","picture":"p","bot":false,"x":null}`: 3,
		`{}`:       0,
		`not json`: 0,
		``:         0,
	} {
		if got := listItemCount(profile(content)); got != want {
			t.Errorf("%q: items = %d, want %d", content, got, want)
		}
	}
}
