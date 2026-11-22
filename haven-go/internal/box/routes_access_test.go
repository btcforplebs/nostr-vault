package box

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const blockNpub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

func TestBlocklistReadAnyWriteFirstOnly(t *testing.T) {
	shortAsk(t)
	srv, owner, member, api := signedInAPI(t)
	dir := api.Mover.Engine.VaultDir()
	fakeEngineJobs(t, dir, map[string]int{"blocklist": 1})
	if st, out := call(t, srv, &member, "GET", "/api/box/blocklist", nil); st != 200 || len(out["npubs"].([]any)) != 0 {
		t.Fatalf("empty: %d %v", st, out)
	}
	body := jsonBody(map[string][]string{"npubs": {blockNpub, " " + blockNpub}})
	if st, _ := call(t, srv, &member, "POST", "/api/box/blocklist", body); st != 403 {
		t.Fatalf("member wrote the box's block list: %d", st)
	}
	st, out := call(t, srv, &owner, "POST", "/api/box/blocklist", body)
	if st != 200 || out["answered"] != true || out["blocked"].(float64) != 1 || len(out["npubs"].([]any)) != 1 {
		t.Fatalf("put: %d %v", st, out)
	}
	var file []string
	raw, _ := os.ReadFile(filepath.Join(dir, "blacklisted_npubs.json"))
	json.Unmarshal(raw, &file)
	if len(file) != 1 || file[0] != blockNpub {
		t.Fatalf("file %v", file)
	}
	if st, out := call(t, srv, &owner, "POST", "/api/box/blocklist", jsonBody(map[string][]string{"npubs": {"nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"}})); st != 400 || !strings.Contains(out["error"].(string), "secret key") {
		t.Fatalf("a pasted secret key must be named as one: %d %v", st, out)
	}
	time.Sleep(1100 * time.Millisecond) // the nsec body again below would be the same NIP-98 event
	for _, bad := range []string{"nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5", "npub1nope", ""} {
		if st, _ := call(t, srv, &owner, "POST", "/api/box/blocklist", jsonBody(map[string][]string{"npubs": {bad}})); st != 400 {
			t.Errorf("%q: %d, want 400", bad, st)
		}
	}
	raw2, _ := os.ReadFile(filepath.Join(dir, "blacklisted_npubs.json"))
	if string(raw2) != string(raw) {
		t.Fatal("a refused list changed the file")
	}
}

func TestTrustRefreshAndProgress(t *testing.T) {
	shortAsk(t)
	srv, _, member, api := signedInAPI(t)
	fakeEngineJobs(t, api.Mover.Engine.VaultDir(), map[string]int{"wot": 0})
	st, out := call(t, srv, &member, "POST", "/api/box/trust/refresh", nil)
	if st != 200 || out["answered"] != true || out["message"] != "Rebuilding who can reach you." {
		t.Fatalf("refresh: %d %v", st, out)
	}
	st, out = call(t, srv, &member, "GET", "/api/box/trust", nil)
	if st != 200 || out["trust"].(map[string]any)["found"].(float64) != 9 || out["last"].(map[string]any)["seq"].(float64) != 1 {
		t.Fatalf("trust: %d %v", st, out)
	}
}
