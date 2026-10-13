package main

import "testing"

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
	for _, bad := range []string{"a:b", "a b", "../x", string(make([]byte, 65))} {
		if storePrefixRe.MatchString(bad) {
			t.Errorf("storePrefix %q accepted", bad)
		}
	}
}
