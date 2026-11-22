package box

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// signedInAPI: accountsAPI with one added account that has signed in.
func signedInAPI(t *testing.T) (*httptest.Server, testKey, testKey, *API) {
	t.Helper()
	srv, owner, api, _, _ := accountsAPI(t)
	member := newTestKey(t)
	if _, err := api.Accounts.Join(member.pk, "Work"); err != nil {
		t.Fatal(err)
	}
	return srv, owner, member, api
}

func TestContentsSplitAndMediaByType(t *testing.T) {
	srv, owner, member, api := signedInAPI(t)
	boxMedia.mu.Lock()
	boxMedia.dir = "" // a fresh measure for this test's vault
	boxMedia.mu.Unlock()
	blossom := filepath.Join(api.Mover.Engine.VaultDir(), "blossom")
	files := map[string][]byte{
		strings.Repeat("01", 32): append([]byte{0x89, 'P', 'N', 'G'}, make([]byte, 20)...),
		strings.Repeat("02", 32): append([]byte("\x00\x00\x00\x18ftypisom"), make([]byte, 20)...),
		strings.Repeat("03", 32): append([]byte("\x00\x00\x00\x18ftypheic"), make([]byte, 20)...),
		strings.Repeat("04", 32): []byte("ID3\x04 an mp3"),
	}
	for name, b := range files {
		if err := os.WriteFile(filepath.Join(blossom, name), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, k := range []testKey{owner, member} {
		code, out := call(t, srv, &k, "GET", "/api/box/contents", nil)
		if code != 200 {
			t.Fatalf("contents: %d %v", code, out)
		}
		media := out["media"].(map[string]any)
		if media["count"].(float64) != 5 { // makeVault's "blob" + the four above
			t.Fatalf("media count: %v", media)
		}
		buckets := media["buckets"].(map[string]any)
		for b, want := range map[string]float64{"image": 2, "video": 1, "audio": 1, "other": 1} {
			if got := buckets[b].(map[string]any)["count"].(float64); got != want {
				t.Errorf("%s: %v, want %v (%v)", b, got, want, buckets)
			}
		}
		split := out["split"].(map[string]any)
		if split["database"].(float64) == 0 || split["media"].(float64) == 0 || split["other"].(float64) == 0 {
			t.Errorf("split: %v", split)
		}
	}
}

func TestContentsAndConnectionsRefuseOutsiders(t *testing.T) {
	srv, _, _, api := signedInAPI(t)
	watch := newTestKey(t)
	if _, err := api.Accounts.AddWatchOnly(npubOf(t, watch), ""); err != nil {
		t.Fatal(err)
	}
	stranger := newTestKey(t)
	for _, p := range []string{"/api/box/contents", "/api/box/connections", "/api/box/logs"} {
		for _, k := range []testKey{watch, stranger} {
			if code, _ := call(t, srv, &k, "GET", p, nil); code != 403 {
				t.Errorf("%s: %d, want 403", p, code)
			}
		}
	}
}

func TestMediaMeterKeepsTypes(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, strings.Repeat("aa", 32))
	os.WriteFile(p, []byte("GIF89a......"), 0o600)
	m := &MediaMeter{TTL: time.Nanosecond}
	if got := m.Measure(dir); got.Buckets["image"].Count != 1 {
		t.Fatalf("first: %+v", got)
	}
	// Same size and time: the kept type is used, not the bytes read again.
	info, _ := os.Stat(p)
	os.WriteFile(p, []byte("ID3.........."[:12]), 0o600)
	os.Chtimes(p, info.ModTime(), info.ModTime())
	time.Sleep(time.Millisecond)
	if got := m.Measure(dir); got.Buckets["image"].Count != 1 {
		t.Fatalf("kept: %+v", got)
	}
	// A new time: read again.
	later := info.ModTime().Add(time.Second)
	os.Chtimes(p, later, later)
	time.Sleep(time.Millisecond)
	if got := m.Measure(dir); got.Buckets["audio"].Count != 1 {
		t.Fatalf("re-read: %+v", got)
	}
	os.Remove(p)
	time.Sleep(time.Millisecond)
	if got := m.Measure(dir); got.Count != 0 || len(m.typed) != 0 {
		t.Fatalf("removed: %+v %d", got, len(m.typed))
	}
}

func TestMediaBucketOf(t *testing.T) {
	for in, want := range map[string]string{
		"\xff\xd8\xff\xe0": "image", "RIFF\x00\x00\x00\x00WEBPVP8 ": "image", "<svg xmlns": "image",
		"\x00\x00\x00\x20ftypM4A ": "audio", "\x00\x00\x00\x20ftypavif": "image", "\x00\x00\x00\x20ftypqt  ": "video",
		"\x1a\x45\xdf\xa3": "video", "OggS": "audio", "RIFF\x00\x00\x00\x00WAVEfmt ": "audio",
		"{\"a\":1}": "other", "ab": "other",
	} {
		if got := mediaBucketOf([]byte(in)); got != want {
			t.Errorf("%q: %s, want %s", in, got, want)
		}
	}
}

// A relay WebSocket through the front door counts as open until the engine
// lets go of it, by route; other engine traffic is not counted.
func TestConnectionsCountsOpenRelaySockets(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	hold, entered := make(chan struct{}), make(chan struct{}, 4)
	var release sync.Once
	letGo := func() { release.Do(func() { close(hold) }) }
	t.Cleanup(letGo) // a failed check must not leave the server waiting on held sockets
	srv.Config.Handler = &Front{API: api, Engine: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		if r.Header.Get("Upgrade") != "" {
			<-hold
		}
	})}
	open := func(path string) {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		req.Header.Set("Upgrade", "websocket")
		req.Header.Set("Connection", "Upgrade")
		go http.DefaultClient.Do(req)
		<-entered
	}
	open("/private")
	open("/")
	open("/nope")
	http.Post(srv.URL+"/upload", "application/octet-stream", nil) // Blossom: not a relay socket
	<-entered
	code, out := call(t, srv, &owner, "GET", "/api/box/connections", nil)
	if code != 200 || out["open"].(float64) != 3 {
		t.Fatalf("connections: %d %v", code, out)
	}
	by := out["byRoute"].(map[string]any)
	if by["/private"].(float64) != 1 || by["/"].(float64) != 1 || by["other"].(float64) != 1 {
		t.Fatalf("byRoute: %v", by)
	}
	letGo()
	deadline := time.Now().Add(2 * time.Second)
	for relayConns.snapshot().Open != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("still open after close: %+v", relayConns.snapshot())
		}
		time.Sleep(5 * time.Millisecond)
	}
}
