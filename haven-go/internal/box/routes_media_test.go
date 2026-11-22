package box

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

var mediaNonce int

// callAny is call for any method with a body (call drops non-POST bodies).
func callAny(t *testing.T, srv *httptest.Server, k testKey, method, path string, body []byte) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, srv.URL+path, bytes.NewReader(body))
	// A nonce tag: the same request twice in one second is otherwise the
	// same event, which the replay check refuses.
	mediaNonce++
	tags := nostr.Tags{{"u", srv.URL + path}, {"method", method}, {"nonce", itoa(mediaNonce)}}
	if body != nil {
		sum := sha256.Sum256(body)
		tags = append(tags, nostr.Tag{"payload", hex.EncodeToString(sum[:])})
	}
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: tags})
	raw, _ := json.Marshal(ev)
	req.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(raw))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ = io.ReadAll(resp.Body)
	var out map[string]any
	json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func readVaultJSON(t *testing.T, api *API, name string) map[string]any {
	t.Helper()
	var out map[string]any
	raw, err := os.ReadFile(filepath.Join(api.Mover.Engine.VaultDir(), name))
	if err != nil {
		return nil
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return out
}

// The switch is the first account's; run now needs it on; an added
// signed-in account may read it and ask for a run but not flip it.
func TestAutoMirrorRoutes(t *testing.T) {
	srv, owner, api, _, _ := accountsAPI(t)
	other := newTestKey(t)
	if _, err := api.Accounts.Join(other.pk, "Work"); err != nil {
		t.Fatal(err)
	}

	if st, out := callAny(t, srv, owner, "GET", "/api/box/media/auto-mirror", nil); st != 200 || out["enabled"] != false {
		t.Fatalf("off by default: %d %v", st, out)
	}
	if st, _ := callAny(t, srv, owner, "POST", "/api/box/media/auto-mirror/run", nil); st != http.StatusConflict {
		t.Fatalf("run while off: %d", st)
	}
	if st, _ := callAny(t, srv, other, "PUT", "/api/box/media/auto-mirror", []byte(`{"enabled":true}`)); st != http.StatusForbidden {
		t.Fatalf("added account flips the switch: %d", st)
	}
	if st, _ := callAny(t, srv, owner, "PUT", "/api/box/media/auto-mirror", []byte(`{}`)); st != http.StatusBadRequest {
		t.Fatalf("no enabled field: %d", st)
	}
	if st, out := callAny(t, srv, owner, "PUT", "/api/box/media/auto-mirror", []byte(`{"enabled":true}`)); st != 200 || out["enabled"] != true {
		t.Fatalf("turn on: %d %v", st, out)
	}
	if f := readVaultJSON(t, api, autoMirrorSettingsName); f["enabled"] != true {
		t.Fatalf("engine file: %v", f)
	}
	if st, out := callAny(t, srv, other, "POST", "/api/box/media/auto-mirror/run", nil); st != 200 || out["runNowAt"].(float64) == 0 {
		t.Fatalf("run now: %d %v", st, out)
	}
	if f := readVaultJSON(t, api, autoMirrorSettingsName); f["enabled"] != true || f["run_now_at"].(float64) == 0 {
		t.Fatalf("run now kept the switch: %v", f)
	}
	// The engine's state comes back as written.
	os.WriteFile(filepath.Join(api.Mover.Engine.VaultDir(), autoMirrorStateName), []byte(`{"last_start":5,"last":{"saved":3}}`), 0o600)
	if _, out := callAny(t, srv, owner, "GET", "/api/box/media/auto-mirror", nil); out["state"].(map[string]any)["last_start"] != float64(5) {
		t.Fatalf("state: %v", out)
	}
}

// A copy job is always the caller's: the request carries the caller's key
// whatever the body says, and one account never sees another's job.
func TestMediaCopyRoutes(t *testing.T) {
	srv, owner, api, _, _ := accountsAPI(t)
	other := newTestKey(t)
	if _, err := api.Accounts.Join(other.pk, ""); err != nil {
		t.Fatal(err)
	}
	if st, _ := callAny(t, srv, other, "POST", "/api/box/media/copy/check", []byte(`{"pubkey":"`+owner.pk+`"}`)); st != http.StatusAccepted {
		t.Fatalf("check: %d", st)
	}
	if f := readVaultJSON(t, api, mediaCopyRequestName); f["pubkey"] != other.pk || f["action"] != "check" {
		t.Fatalf("request: %v", f)
	}
	if _, out := callAny(t, srv, other, "GET", "/api/box/media/copy", nil); out["queued"] != true {
		t.Fatalf("own queued job: %v", out)
	}
	if _, out := callAny(t, srv, owner, "GET", "/api/box/media/copy", nil); out["queued"] != false {
		t.Fatalf("another's queued job shown: %v", out)
	}

	if st, _ := callAny(t, srv, owner, "POST", "/api/box/media/copy", []byte(`{"auths":[]}`)); st != http.StatusBadRequest {
		t.Fatalf("no auths: %d", st)
	}
	body, _ := json.Marshal(map[string]any{"auths": []string{"x"}, "pubkey": other.pk})
	if st, _ := callAny(t, srv, owner, "POST", "/api/box/media/copy", body); st != http.StatusAccepted {
		t.Fatalf("copy: %d", st)
	}
	if f := readVaultJSON(t, api, mediaCopyRequestName); f["pubkey"] != owner.pk || f["action"] != "copy" {
		t.Fatalf("copy request: %v", f)
	}

	os.WriteFile(filepath.Join(api.Mover.Engine.VaultDir(), mediaCopyStateName), []byte(`{"pubkey":"`+owner.pk+`","copied":2}`), 0o600)
	if _, out := callAny(t, srv, owner, "GET", "/api/box/media/copy", nil); out["state"].(map[string]any)["copied"] != float64(2) {
		t.Fatalf("own state: %v", out)
	}
	if _, out := callAny(t, srv, other, "GET", "/api/box/media/copy", nil); out["state"] != nil {
		t.Fatalf("another's state shown: %v", out)
	}
	// A watch-only or unknown key gets nothing.
	if st, _ := callAny(t, srv, newTestKey(t), "GET", "/api/box/media/copy", nil); st != http.StatusForbidden {
		t.Fatalf("stranger: %d", st)
	}
}
