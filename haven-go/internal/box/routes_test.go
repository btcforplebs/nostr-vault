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
		"GET /api/box/accounts",
		"GET /api/box/accounts/me",
		"GET /api/box/backups",
		"GET /api/box/blocklist",
		"GET /api/box/connections",
		"GET /api/box/contents",
		"GET /api/box/devices",
		"GET /api/box/imports",
		"GET /api/box/logs",
		"GET /api/box/status",
		"GET /api/box/storage",
		"GET /api/box/sync",
		"GET /api/box/trust",
		"POST /api/box/accounts/add",
		"POST /api/box/accounts/code",
		"POST /api/box/accounts/join",
		"POST /api/box/accounts/remove",
		"POST /api/box/backups/now",
		"POST /api/box/backups/restore",
		"POST /api/box/blocklist",
		"POST /api/box/imports/cancel",
		"POST /api/box/imports/run",
		"POST /api/box/move",
		"POST /api/box/restart",
		"POST /api/box/sync/first",
		"POST /api/box/sync/now",
		"POST /api/box/trust/refresh",
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

// Every route is first-account only except the two that let an account
// ask whether the box holds it and join with a code (E9), the read routes
// any signed-in account may use (E4), and the sync routes (E3: any
// signed-in account may see a round runs and ask for one now; a first copy
// stays the first account's, Tron #2385 M1). Opening any other route to
// more callers must be a deliberate edit here.
func TestRouteLevels(t *testing.T) {
	anyone := map[string]bool{"GET /api/box/accounts/me": true, "POST /api/box/accounts/join": true}
	signedIn := map[string]bool{"GET /api/box/contents": true, "GET /api/box/connections": true,
		"GET /api/box/sync": true, "POST /api/box/sync/now": true,
		"GET /api/box/imports": true, "POST /api/box/imports/run": true, "POST /api/box/imports/cancel": true,
		"GET /api/box/trust": true, "POST /api/box/trust/refresh": true, "GET /api/box/blocklist": true}
	for path, rt := range boxRoutes {
		want := FirstAccount
		if anyone[path] {
			want = Anyone
		} else if signedIn[path] {
			want = SignedIn
		}
		if rt.level != want {
			t.Errorf("%s: level %d, want %d", path, rt.level, want)
		}
	}
}

func TestCallerLevels(t *testing.T) {
	first, other, outsider := Caller{Pubkey: "a", First: true}, Caller{Pubkey: "b", SignedIn: true}, Caller{Pubkey: "c"}
	if !first.may(FirstAccount) || !first.may(SignedIn) || !first.may(Anyone) {
		t.Fatal("the first account may use every route")
	}
	if other.may(FirstAccount) || !other.may(SignedIn) || !other.may(Anyone) {
		t.Fatal("a signed-in added account may use only signed-in and anyone routes")
	}
	if outsider.may(FirstAccount) || outsider.may(SignedIn) || !outsider.may(Anyone) {
		t.Fatal("a key the box does not hold may use only anyone routes")
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
