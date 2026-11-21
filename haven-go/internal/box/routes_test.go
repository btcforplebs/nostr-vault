package box

import (
	"net/http"
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

// Every route is first-account only until the box holds several accounts
// (One Vault addendum A.4, E7: no behaviour change).
func TestRoutesAreFirstAccountOnly(t *testing.T) {
	for path, rt := range boxRoutes {
		if rt.level != FirstAccount {
			t.Errorf("%s: level %d, want FirstAccount", path, rt.level)
		}
	}
}

func TestCallerLevels(t *testing.T) {
	first, other := Caller{Pubkey: "a", First: true}, Caller{Pubkey: "b"}
	if !first.may(FirstAccount) || !first.may(SignedIn) {
		t.Fatal("the first account may use every route")
	}
	if other.may(FirstAccount) || !other.may(SignedIn) {
		t.Fatal("an added account may use only signed-in routes")
	}
}

// The handler is told who asked: today always the first account.
func TestHandlerIsToldWhoAsked(t *testing.T) {
	srv, owner, _ := newTestAPI(t)
	var got Caller
	handle("GET /api/box/test-caller", FirstAccount, func(_ *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		got = c
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	t.Cleanup(func() { delete(boxRoutes, "GET /api/box/test-caller") })
	if code, _ := call(t, srv, &owner, "GET", "/api/box/test-caller", nil); code != 200 {
		t.Fatalf("owner: %d", code)
	}
	if got.Pubkey != owner.pk || !got.First {
		t.Fatalf("caller = %+v, want the owner as first account", got)
	}
}
