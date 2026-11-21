package box

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr/nip19"
)

const testCode = "setup-code-0123456789"

func newTestClaim(t *testing.T) (*Claim, *httptest.Server, *time.Time) {
	now := time.Unix(1_800_000_000, 0)
	c := &Claim{Code: testCode, OwnerFile: filepath.Join(t.TempDir(), "box", "owner"), Done: make(chan struct{}), Now: func() time.Time { return now }}
	srv := httptest.NewServer(c)
	t.Cleanup(srv.Close)
	return c, srv, &now
}

func claimPost(t *testing.T, srv *httptest.Server, npub, code string) (int, string) {
	t.Helper()
	resp, err := http.PostForm(srv.URL+"/setup", url.Values{"npub": {npub}, "code": {code}})
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b := new(bytes.Buffer)
	_, _ = b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

func TestClaimNeedsTheCode(t *testing.T) {
	c, srv, _ := newTestClaim(t)
	visitor := npubOf(t, newTestKey(t))
	for _, code := range []string{"", "x", strings.ToUpper(testCode), testCode[1:], testCode + " x"} {
		if st, _ := claimPost(t, srv, visitor, code); st != http.StatusForbidden {
			t.Fatalf("code %q: %d, want 403", code, st)
		}
		if _, err := os.Stat(c.OwnerFile); !os.IsNotExist(err) {
			t.Fatalf("a wrong code saved an owner: %v", err)
		}
	}
	select {
	case <-c.Done:
		t.Fatal("Done closed without a claim")
	default:
	}
}

func TestClaimSavesOwnerOnce(t *testing.T) {
	c, srv, _ := newTestClaim(t)
	owner, other := npubOf(t, newTestKey(t)), npubOf(t, newTestKey(t))
	if st, body := claimPost(t, srv, "  "+owner+"\n", testCode); st != 200 || !strings.Contains(body, owner) {
		t.Fatalf("claim: %d %s", st, body)
	}
	<-c.Done
	b, _ := os.ReadFile(c.OwnerFile)
	if strings.TrimSpace(string(b)) != owner {
		t.Fatalf("box/owner = %q", b)
	}
	if fi, _ := os.Stat(c.OwnerFile); fi.Mode().Perm() != 0o644 {
		t.Fatalf("box/owner mode %v", fi.Mode())
	}
	if st, _ := claimPost(t, srv, other, testCode); st != http.StatusConflict {
		t.Fatalf("second claim: %d, want 409", st)
	}
	if b2, _ := os.ReadFile(c.OwnerFile); string(b2) != string(b) {
		t.Fatal("second claim changed box/owner")
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(c.OwnerFile), ".owner-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

func TestClaimRefusesBadKeys(t *testing.T) {
	c, srv, _ := newTestClaim(t)
	k := newTestKey(t)
	nsec, _ := nip19.EncodePrivateKey(k.sk)
	if st, body := claimPost(t, srv, nsec, testCode); st != 400 || !strings.Contains(body, "secret key") || strings.Contains(body, nsec) {
		t.Fatalf("nsec: %d (the page must not echo it back)", st)
	}
	for _, bad := range []string{"", "npub1xyz", "hello"} {
		if st, _ := claimPost(t, srv, bad, testCode); st != 400 {
			t.Fatalf("npub %q: %d", bad, st)
		}
	}
	if _, err := os.Stat(c.OwnerFile); !os.IsNotExist(err) {
		t.Fatal("a bad key saved an owner")
	}
}

func TestClaimCapsWrongCodes(t *testing.T) {
	_, srv, now := newTestClaim(t)
	owner := npubOf(t, newTestKey(t))
	for i := 0; i < claimMaxFails; i++ {
		claimPost(t, srv, owner, "guess")
	}
	if st, _ := claimPost(t, srv, owner, testCode); st != http.StatusTooManyRequests {
		t.Fatalf("after %d wrong codes: %d, want 429", claimMaxFails, st)
	}
	*now = now.Add(claimFailWindow)
	if st, _ := claimPost(t, srv, owner, testCode); st != 200 {
		t.Fatalf("after the window: %d, want 200", st)
	}
}

func TestClaimServesOnlyThePage(t *testing.T) {
	_, srv, _ := newTestClaim(t)
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("X-Frame-Options") != "DENY" || !strings.Contains(resp.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("GET / = %d %v", resp.StatusCode, resp.Header)
	}
	for _, p := range []string{"/api/box/status", "/upload", "/private", "/setup/x"} {
		resp, err := http.Get(srv.URL + p)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("GET %s = %d, want 503", p, resp.StatusCode)
		}
	}
}

func TestClaimRaceOneWinner(t *testing.T) {
	c, srv, _ := newTestClaim(t)
	var wg sync.WaitGroup
	wins := make(chan string, 8)
	for i := 0; i < 8; i++ {
		npub := npubOf(t, newTestKey(t))
		wg.Add(1)
		go func() {
			defer wg.Done()
			if st, _ := claimPost(t, srv, npub, testCode); st == 200 {
				wins <- npub
			}
		}()
	}
	wg.Wait()
	close(wins)
	var won []string
	for w := range wins {
		won = append(won, w)
	}
	b, _ := os.ReadFile(c.OwnerFile)
	if len(won) != 1 || strings.TrimSpace(string(b)) != won[0] {
		t.Fatalf("winners %v, box/owner %q", won, b)
	}
}

func TestWriteOwnerFileNeverOverwrites(t *testing.T) {
	p := filepath.Join(t.TempDir(), "box", "owner")
	if err := WriteOwnerFile(p, "npub1first"); err != nil {
		t.Fatal(err)
	}
	if err := WriteOwnerFile(p, "npub1second"); err == nil || !os.IsExist(unwrapAll(err)) {
		t.Fatalf("second write: %v, want exists", err)
	}
	if b, _ := os.ReadFile(p); string(b) != "npub1first\n" {
		t.Fatalf("owner = %q", b)
	}
}

func unwrapAll(err error) error {
	for {
		u, ok := err.(interface{ Unwrap() error })
		if !ok || u.Unwrap() == nil {
			return err
		}
		err = u.Unwrap()
	}
}

func TestConfigOwnerSources(t *testing.T) {
	k, other := newTestKey(t), newTestKey(t)
	data := t.TempDir()
	env := map[string]string{"NV_DATA_DIR": data, "NV_SETUP_CODE": testCode}
	c, err := ConfigFromEnv(envOf(env))
	if err != nil || !c.Claiming() || c.SetupCode != testCode {
		t.Fatalf("no owner + code: claiming=%v %v", c.Claiming(), err)
	}
	if _, err := ConfigFromEnv(envOf(map[string]string{"NV_DATA_DIR": data, "NV_SETUP_CODE": "short"})); err == nil || !strings.Contains(err.Error(), "NV_SETUP_CODE") {
		t.Fatalf("short code: %v", err)
	}
	if _, err := ConfigFromEnv(envOf(map[string]string{"NV_DATA_DIR": data})); err == nil || !strings.Contains(err.Error(), "NV_OWNER") {
		t.Fatalf("no owner, no code: %v", err)
	}
	if err := WriteOwnerFile(c.OwnerFile(), npubOf(t, k)); err != nil {
		t.Fatal(err)
	}
	if c, err = ConfigFromEnv(envOf(env)); err != nil || c.Claiming() || c.OwnerHex != k.pk {
		t.Fatalf("box/owner: %+v %v", c, err)
	}
	env["NV_OWNER"] = other.pk // the installer's owner wins
	if c, err = ConfigFromEnv(envOf(env)); err != nil || c.OwnerHex != other.pk {
		t.Fatalf("NV_OWNER over box/owner: %v %v", c.OwnerHex, err)
	}
	delete(env, "NV_OWNER")
	os.WriteFile(c.OwnerFile(), []byte("garbage\n"), 0o644) // broken file: an error, never claim mode again
	if c, err = ConfigFromEnv(envOf(env)); err == nil || c.Claiming() {
		t.Fatalf("broken box/owner: claiming=%v err=%v", c.Claiming(), err)
	}
}

func TestConfigStoreSwitches(t *testing.T) {
	k := newTestKey(t)
	lookup := func(m map[string]string) func(string) (string, bool) {
		return func(key string) (string, bool) { v, ok := m[key]; return v, ok }
	}
	c, err := ConfigFromLookup(lookup(map[string]string{"NV_OWNER": k.pk, "NV_MOVE_ROOT": "", "NV_UPDATE_VIA": "StartOS"}))
	if err != nil || c.MoveRoot != "" || c.UpdateVia != "startos" {
		t.Fatalf("store box: %q %q %v", c.MoveRoot, c.UpdateVia, err)
	}
	if c, _ = ConfigFromLookup(lookup(map[string]string{"NV_OWNER": k.pk})); c.MoveRoot != "/mnt" || c.UpdateVia != "" {
		t.Fatalf("defaults: %q %q", c.MoveRoot, c.UpdateVia)
	}
	if _, err := ConfigFromLookup(lookup(map[string]string{"NV_OWNER": k.pk, "NV_UPDATE_VIA": "flatpak"})); err == nil {
		t.Fatal("unknown NV_UPDATE_VIA must fail")
	}
	if _, err := ConfigFromLookup(lookup(map[string]string{"NV_OWNER": k.pk, "NV_MOVE_ROOT": "mnt"})); err == nil {
		t.Fatal("relative NV_MOVE_ROOT must fail")
	}
}

func TestAPIStoreManaged(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	api.Updater.Store, api.Updater.Hook = "umbrel", "/bin/false"
	api.Mover.Root = ""
	st, up := call(t, srv, &owner, "POST", "/api/box/update", []byte("{}"))
	if st != 200 || up["managed"] != true || up["via"] != "umbrel" || up["started"] != false {
		t.Fatalf("update %d %v", st, up)
	}
	if st, s := call(t, srv, &owner, "GET", "/api/box/status", nil); st != 200 || s["update_via"] != "umbrel" || s["move_off"] != true {
		t.Fatalf("status %d %v", st, s)
	}
	if st, s := call(t, srv, &owner, "GET", "/api/box/storage", nil); st != 200 || s["move_off"] != true {
		t.Fatalf("storage %d %v", st, s)
	}
	if st, mv := call(t, srv, &owner, "POST", "/api/box/move", []byte(`{"path":"/mnt/usb/v"}`)); st != 403 {
		t.Fatalf("move %d %v", st, mv)
	}
	if api.Mover.State() != nil {
		t.Fatal("a move started with Move off")
	}
}

func directPost(c *Claim, addr, npub, code string) int {
	req := httptest.NewRequest("POST", "/setup", strings.NewReader(url.Values{"npub": {npub}, "code": {code}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.RemoteAddr = addr
	w := httptest.NewRecorder()
	c.ServeHTTP(w, req)
	return w.Code
}

func TestClaimCapIsPerClient(t *testing.T) {
	c, _, _ := newTestClaim(t)
	owner := npubOf(t, newTestKey(t))
	for i := 0; i < claimMaxFails+3; i++ {
		directPost(c, "192.168.1.66:4000", owner, "guess")
	}
	if st := directPost(c, "192.168.1.66:4001", owner, testCode); st != http.StatusTooManyRequests {
		t.Fatalf("guesser with the right code: %d, want 429", st)
	}
	if st := directPost(c, "192.168.1.20:5000", owner, testCode); st != 200 {
		t.Fatalf("owner on another address: %d, want 200 (no lockout)", st)
	}
}

func TestClaimCapBoxWide(t *testing.T) {
	c, _, _ := newTestClaim(t)
	owner := npubOf(t, newTestKey(t))
	for i := 0; i < claimMaxFailsAll; i++ {
		directPost(c, "10.0."+itoa(i/250)+"."+itoa(i%250)+":1", owner, "guess")
	}
	if st := directPost(c, "192.168.1.20:5000", owner, testCode); st != http.StatusTooManyRequests {
		t.Fatalf("after %d wrong codes box-wide: %d, want 429", claimMaxFailsAll, st)
	}
	if len(c.limit.fails) > claimMaxClients {
		t.Fatalf("tracked %d clients", len(c.limit.fails))
	}
}

func TestClaimClientMapBounded(t *testing.T) {
	c, _, now := newTestClaim(t)
	for i := 0; i < claimMaxClients+50; i++ {
		directPost(c, "10.1."+itoa(i/250)+"."+itoa(i%250)+":1", "x", "guess")
		if i%90 == 89 {
			*now = now.Add(claimFailWindow) // keep the box-wide cap from stopping the run
		}
	}
	if len(c.limit.fails) > claimMaxClients {
		t.Fatalf("tracked %d clients, cap %d", len(c.limit.fails), claimMaxClients)
	}
}

func TestClaimOwnerAlreadySavedLetsHavendGoOn(t *testing.T) {
	c, srv, _ := newTestClaim(t)
	first := npubOf(t, newTestKey(t))
	if err := WriteOwnerFile(c.OwnerFile, first); err != nil {
		t.Fatal(err)
	}
	if st, _ := claimPost(t, srv, npubOf(t, newTestKey(t)), testCode); st != http.StatusConflict {
		t.Fatalf("claim over a saved owner: %d, want 409", st)
	}
	select {
	case <-c.Done:
	case <-time.After(time.Second):
		t.Fatal("Done not closed: havend would sit in claim mode")
	}
	if b, _ := os.ReadFile(c.OwnerFile); strings.TrimSpace(string(b)) != first {
		t.Fatalf("owner changed: %q", b)
	}
	claimPost(t, srv, npubOf(t, newTestKey(t)), testCode) // a second 409 must not close Done again (panic)
}
