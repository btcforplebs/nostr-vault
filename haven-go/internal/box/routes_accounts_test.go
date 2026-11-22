package box

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// accountsAPI is newTestAPI with an account store and join codes on a
// clock the test moves. changed counts AccountStore.Changed calls.
func accountsAPI(t *testing.T) (srv *httptest.Server, owner testKey, api *API, now *time.Time, changed *atomic.Int32) {
	t.Helper()
	srv, owner, api = newTestAPI(t)
	clock := time.Now()
	now = &clock
	changed = &atomic.Int32{}
	ownerNpub := npubOf(t, owner)
	api.Accounts = &AccountStore{
		Path: filepath.Join(t.TempDir(), "box", "accounts.json"), OwnerHex: owner.pk, OwnerNpub: ownerNpub,
		Now: func() time.Time { return *now }, Changed: func() { changed.Add(1) },
	}
	api.JoinCodes = &JoinCodes{Now: func() time.Time { return *now }}
	return
}

func jsonBody(v any) []byte { b, _ := json.Marshal(v); return b }

func makeCode(t *testing.T, srv *httptest.Server, owner testKey) string {
	t.Helper()
	st, out := call(t, srv, &owner, "POST", "/api/box/accounts/code", nil)
	code, _ := out["code"].(string)
	if st != 200 || len(code) != 14 {
		t.Fatalf("code: %d %v", st, out)
	}
	return code
}

func meState(t *testing.T, srv *httptest.Server, k testKey) string {
	t.Helper()
	st, out := call(t, srv, &k, "GET", "/api/box/accounts/me", nil)
	if st != 200 {
		t.Fatalf("me: %d %v", st, out)
	}
	return out["state"].(string)
}

// A key the box does not hold may ask "do you hold me" and join, nothing
// else, and does not learn which routes exist.
func TestAccountsStrangerGetsOnlyAnyoneRoutes(t *testing.T) {
	srv, owner, _, _, _ := accountsAPI(t)
	stranger := newTestKey(t)
	if s := meState(t, srv, stranger); s != StateNone {
		t.Fatalf("stranger me = %s", s)
	}
	if s := meState(t, srv, owner); s != StateFirst {
		t.Fatalf("owner me = %s", s)
	}
	for _, r := range [][2]string{{"GET", "/api/box/status"}, {"GET", "/api/box/accounts"}, {"POST", "/api/box/accounts/code"}, {"GET", "/api/box/no-such-route"}} {
		if st, _ := call(t, srv, &stranger, r[0], r[1], []byte(`{}`)); st != 403 {
			t.Errorf("stranger %s %s: %d, want 403", r[0], r[1], st)
		}
	}
	if st, _ := call(t, srv, &owner, "GET", "/api/box/no-such-route", nil); st != 404 {
		t.Errorf("owner unknown route: %d, want 404", st)
	}
}

func TestAccountsJoinWithCode(t *testing.T) {
	srv, owner, api, _, changed := accountsAPI(t)
	joiner, other := newTestKey(t), newTestKey(t)
	code := makeCode(t, srv, owner)

	if st, _ := call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": "AAAA-BBBB-CCCC"})); st != 403 {
		t.Fatalf("wrong code: %d, want 403", st)
	}
	// Typed with spaces and in lower case: the same code.
	typed := strings.ToLower(strings.ReplaceAll(code, "-", " "))
	st, out := call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": typed, "name": "Work\x00 "}))
	if st != 200 || out["state"] != StateSignedIn || out["name"] != "Work" {
		t.Fatalf("join: %d %v", st, out)
	}
	if changed.Load() != 1 {
		t.Fatalf("Changed called %d times, want 1 (the engine must reload)", changed.Load())
	}
	saved := LoadAccounts(api.Accounts.Path)
	if len(saved) != 1 || saved[0].Npub != npubOf(t, joiner) || !saved[0].SignedIn {
		t.Fatalf("accounts.json = %+v", saved)
	}
	if s := meState(t, srv, joiner); s != StateSignedIn {
		t.Fatalf("joiner me = %s", s)
	}
	// One use.
	if st, _ := call(t, srv, &other, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code})); st != 403 {
		t.Fatalf("code used twice: %d, want 403", st)
	}
	// Joining again: nothing to do, and a fresh code is not spent.
	time.Sleep(1100 * time.Millisecond) // a new second: an identical NIP-98 event would be a replay
	code2 := makeCode(t, srv, owner)
	if st, out := call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code2})); st != 200 || out["already"] != true {
		t.Fatalf("rejoin: %d %v", st, out)
	}
	if st, _ := call(t, srv, &other, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code2})); st != 200 {
		t.Fatalf("code spent by a rejoin: %d", st)
	}

	// A signed-in added account is a member, not the first account: every
	// box control is still the first account's.
	for _, r := range [][2]string{{"GET", "/api/box/status"}, {"GET", "/api/box/accounts"}, {"POST", "/api/box/accounts/code"}, {"POST", "/api/box/accounts/add"}, {"POST", "/api/box/accounts/remove"}, {"POST", "/api/box/update"}} {
		st, out := call(t, srv, &joiner, r[0], r[1], []byte(`{}`))
		if st != 403 || !strings.Contains(out["error"].(string), "first account") {
			t.Errorf("signed-in %s %s: %d %v, want 403 first account only", r[0], r[1], st, out)
		}
	}

	st, out = call(t, srv, &owner, "GET", "/api/box/accounts", nil)
	list, _ := out["accounts"].([]any)
	if st != 200 || len(list) != 3 || list[0].(map[string]any)["state"] != StateFirst {
		t.Fatalf("list: %d %v", st, out)
	}
}

func TestAccountsFirstAccountCannotJoin(t *testing.T) {
	srv, owner, _, _, _ := accountsAPI(t)
	code := makeCode(t, srv, owner)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code})); st != 409 {
		t.Fatalf("first account join: %d, want 409", st)
	}
}

// Added by npub alone, an account reads nothing private and gets no box
// control, even when it signs; only joining with a code signs it in.
func TestAccountsWatchOnlyNeedsACode(t *testing.T) {
	srv, owner, _, _, changed := accountsAPI(t)
	watch := newTestKey(t)
	st, out := call(t, srv, &owner, "POST", "/api/box/accounts/add", jsonBody(map[string]string{"npub": watch.pk, "name": "Mirror"}))
	if st != 200 || out["state"] != StateWatchOnly || out["npub"] != npubOf(t, watch) {
		t.Fatalf("add: %d %v", st, out)
	}
	if changed.Load() != 1 {
		t.Fatal("add did not reload the engine")
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/add", jsonBody(map[string]string{"npub": npubOf(t, watch)})); st != 409 {
		t.Fatalf("added twice: %d, want 409", st)
	}
	if s := meState(t, srv, watch); s != StateWatchOnly {
		t.Fatalf("watch me = %s", s)
	}
	time.Sleep(1100 * time.Millisecond) // a new second: an identical NIP-98 event would be a replay
	if s := meState(t, srv, watch); s != StateWatchOnly {
		t.Fatalf("signing to the box signed it in: %s", s)
	}
	if st, _ := call(t, srv, &watch, "GET", "/api/box/status", nil); st != 403 {
		t.Fatalf("watch-only status: %d", st)
	}
	code := makeCode(t, srv, owner)
	if st, out := call(t, srv, &watch, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code})); st != 200 || out["state"] != StateSignedIn || out["name"] != "Mirror" {
		t.Fatalf("watch join: %d %v", st, out)
	}
}

func TestAccountsSecretKeysRefused(t *testing.T) {
	srv, owner, api, _, _ := accountsAPI(t)
	nsec, _ := nip19.EncodePrivateKey(nostr.GeneratePrivateKey())
	for _, path := range []string{"/api/box/accounts/add", "/api/box/accounts/remove"} {
		st, out := call(t, srv, &owner, "POST", path, jsonBody(map[string]string{"npub": nsec}))
		if st != 400 || out["error"] != nsecRefused {
			t.Errorf("%s nsec: %d %v", path, st, out)
		}
	}
	joiner := newTestKey(t)
	if st, out := call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": nsec})); st != 400 || out["error"] != nsecRefused {
		t.Errorf("join nsec: %d %v", st, out)
	}
	if _, err := os.Stat(api.Accounts.Path); !os.IsNotExist(err) {
		t.Fatal("a refused request wrote accounts.json")
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/add", jsonBody(map[string]string{"npub": "npub1nope"})); st != 400 {
		t.Errorf("bad npub: %d", st)
	}
}

func TestAccountsRemoveKeepsNothingButRefusesFirst(t *testing.T) {
	srv, owner, api, _, changed := accountsAPI(t)
	joiner := newTestKey(t)
	code := makeCode(t, srv, owner)
	call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code}))
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/remove", jsonBody(map[string]string{"npub": npubOf(t, owner)})); st != 409 {
		t.Fatalf("remove first: %d, want 409", st)
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/remove", jsonBody(map[string]string{"npub": npubOf(t, newTestKey(t))})); st != 404 {
		t.Fatalf("remove unknown: %d, want 404", st)
	}
	n := changed.Load()
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/remove", jsonBody(map[string]string{"npub": npubOf(t, joiner)})); st != 200 {
		t.Fatalf("remove: %d", st)
	}
	if changed.Load() != n+1 || len(LoadAccounts(api.Accounts.Path)) != 0 {
		t.Fatal("remove did not save and reload")
	}
	if s := meState(t, srv, joiner); s != StateNone {
		t.Fatalf("removed me = %s", s)
	}
	if st, _ := call(t, srv, &joiner, "GET", "/api/box/status", nil); st != 403 {
		t.Fatalf("removed account status: %d", st)
	}
}

func TestAccountsCodeExpires(t *testing.T) {
	srv, owner, _, now, _ := accountsAPI(t)
	code := makeCode(t, srv, owner)
	*now = now.Add(joinCodeTTL + time.Second)
	joiner := newTestKey(t)
	if st, _ := call(t, srv, &joiner, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code})); st != 403 {
		t.Fatalf("expired code: %d, want 403", st)
	}
}

func TestAccountsWrongCodesAreCapped(t *testing.T) {
	srv, owner, _, _, _ := accountsAPI(t)
	code := makeCode(t, srv, owner)
	guesser := newTestKey(t)
	for i := 0; i < claimMaxFails; i++ {
		call(t, srv, &guesser, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": "WRONG-CODE-" + itoa(i)}))
	}
	if st, _ := call(t, srv, &guesser, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": code})); st != 429 {
		t.Fatalf("right code after %d wrong: %d, want 429", claimMaxFails, st)
	}
}

// A join header works once.
func TestAccountsJoinReplayRefused(t *testing.T) {
	srv, owner, _, _, _ := accountsAPI(t)
	joiner := newTestKey(t)
	body := jsonBody(map[string]string{"code": makeCode(t, srv, owner)})
	auth := joiner.authHeader(t, "POST", srv.URL+"/api/box/accounts/join", body, time.Now())
	do := func() int {
		req, _ := http.NewRequest("POST", srv.URL+"/api/box/accounts/join", bytes.NewReader(body))
		req.Header.Set("Authorization", auth)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if st := do(); st != 200 {
		t.Fatalf("first: %d", st)
	}
	if st := do(); st != 401 {
		t.Fatalf("replay: %d, want 401", st)
	}
}

// A damaged accounts.json is never overwritten with a shorter list.
func TestAccountsDamagedFileNotOverwritten(t *testing.T) {
	srv, owner, api, _, _ := accountsAPI(t)
	os.MkdirAll(filepath.Dir(api.Accounts.Path), 0o700)
	os.WriteFile(api.Accounts.Path, []byte("[{broken"), 0o600)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/accounts/add", jsonBody(map[string]string{"npub": npubOf(t, newTestKey(t))})); st != 500 {
		t.Fatalf("add on a damaged file: %d, want 500", st)
	}
	if b, _ := os.ReadFile(api.Accounts.Path); string(b) != "[{broken" {
		t.Fatalf("damaged file overwritten: %q", b)
	}
}
