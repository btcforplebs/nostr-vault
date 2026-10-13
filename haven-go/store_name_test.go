package main

import (
	"strings"
	"testing"
)

func TestStoreNamePerAccount(t *testing.T) {
	for _, c := range []struct{ prefix, path, want string }{
		{"", "db/feed", "haven:feed"},
		{"", "db/outbox", "haven:outbox"},
		{"ab12", "db/feed", "haven:ab12:feed"},
		{"ab12", "db/private", "haven:ab12:private"},
	} {
		if got := storeName(c.prefix, c.path); got != c.want {
			t.Errorf("storeName(%q, %q) = %q, want %q", c.prefix, c.path, got, c.want)
		}
	}
	for _, bad := range []string{"a:b", "a b", "../x", strings.Repeat("a", 65), ""} {
		if storePrefixRe.MatchString(bad) {
			t.Errorf("storePrefix %q accepted", bad)
		}
	}
	for _, good := range []string{"a", strings.Repeat("a", 64), strings.Repeat("0f", 32), "A-b_9"} {
		if !storePrefixRe.MatchString(good) {
			t.Errorf("storePrefix %q rejected", good)
		}
	}
}
