package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// The relay port (not the mesh door) answered /list/<owner> and every blob
// to anyone who reached it: the LAN (Mac on 0.0.0.0), a relay domain or
// tunnel, a web page on the same machine (Tron, mesh attack review item 1).
// Now /list, and HEAD of a blob no public note names, need the owner's or a
// paired device's signed auth, unless the request is the owner's own app:
// from this machine, not through a tunnel, not from a web page. GET by exact
// hash stays open (Logen's pick B).
func TestRelayPortBlobGate(t *testing.T) {
	sk, pk := withOwner(t)
	db := withOutbox(t)
	posted, private := blobHash('d'), blobHash('e')

	note := nostr.Event{PubKey: pk, Kind: 1, CreatedAt: nostr.Now(), Content: "a photo",
		Tags: nostr.Tags{{"imeta", "url https://blossom.example/" + posted + ".jpg", "x " + posted}}}
	note.Sign(sk)
	if err := db.SaveEvent(context.Background(), &note); err != nil {
		t.Fatal(err)
	}
	// A DM naming a blob does not make it public.
	dm := nostr.Event{PubKey: pk, Kind: 14, CreatedAt: nostr.Now(), Content: "https://vault.example/" + private + ".jpg"}
	dm.Sign(sk)
	if err := db.SaveEvent(context.Background(), &dm); err != nil {
		t.Fatal(err)
	}

	savedRelay, savedFs, savedPath := outboxRelay, fs, config.BlossomPath
	t.Cleanup(func() { outboxRelay, fs, config.BlossomPath = savedRelay, savedFs, savedPath })
	outboxRelay, fs, config.BlossomPath = khatru.NewRelay(), afero.NewMemMapFs(), "/blobs/"
	index := newTestBackend(t, "blossom")
	if err := index.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(index.Close)
	bs := blossom.New(outboxRelay, "http://vault.example")
	bs.Store = blossom.EventStoreBlobIndexWrapper{Store: index, ServiceURL: bs.ServiceURL}
	bs.LoadBlob = append(bs.LoadBlob, loadBlob)
	guardMeshBlobs(bs)
	guardRelayBlobs(bs)
	for _, h := range []string{posted, private} {
		if err := afero.WriteFile(fs, config.BlossomPath+h, []byte("blob "+h[:1]), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := bs.Store.Keep(context.Background(), blossom.BlobDescriptor{SHA256: h, Size: 6, Type: "image/jpeg", Uploaded: nostr.Now()}, pk); err != nil {
			t.Fatal(err)
		}
	}

	signed := func(signer, verb, x string) string {
		ev := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: verb,
			Tags: nostr.Tags{{"t", verb}, {"expiration", strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)}}}
		if x != "" {
			ev.Tags = append(ev.Tags, nostr.Tag{"x", x})
		}
		ev.Sign(signer)
		j, _ := json.Marshal(ev)
		return "Nostr " + base64.StdEncoding.EncodeToString(j)
	}

	type from struct {
		name    string
		remote  string
		headers map[string]string
		ownApp  bool
		host    string // "" = 127.0.0.1:3355, what the apps dial
	}
	froms := []from{
		{"own app (loopback)", "127.0.0.1:50000", nil, true, ""},
		{"own app (::1)", "[::1]:50000", nil, true, "[::1]:3355"},
		{"own app (localhost)", "127.0.0.1:50000", nil, true, "localhost:3355"},
		{"DNS rebinding (loopback, foreign Host)", "127.0.0.1:50000", nil, false, "evil.example:3355"},
		{"proxy with only Via", "127.0.0.1:50000", map[string]string{"Via": "1.1 proxy"}, false, ""},
		{"proxy with only X-Forwarded-Host", "127.0.0.1:50000", map[string]string{"X-Forwarded-Host": "vault.example"}, false, ""},
		{"proxy with only X-Forwarded-Proto", "127.0.0.1:50000", map[string]string{"X-Forwarded-Proto": "https"}, false, ""},
		{"LAN", "192.168.1.20:50000", nil, false, ""},
		{"tunnel (Cloudflare on loopback)", "127.0.0.1:50000", map[string]string{"Cf-Connecting-Ip": "203.0.113.9", "Cf-Ray": "x"}, false, ""},
		{"proxy naming a LAN client", "127.0.0.1:50000", map[string]string{"X-Forwarded-For": "192.168.1.20"}, false, ""},
		{"web page fetch (Origin)", "127.0.0.1:50000", map[string]string{"Origin": "https://evil.example"}, false, ""},
		{"web page <img> (Sec-Fetch-Site)", "127.0.0.1:50000", map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors"}, false, ""},
	}

	do := func(f from, method, path, auth string) int {
		req := httptest.NewRequest(method, path, nil)
		req.RemoteAddr = f.remote
		req.Host = "127.0.0.1:3355"
		if f.host != "" {
			req.Host = f.host
		}
		for k, v := range f.headers {
			req.Header.Set(k, v)
		}
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		w := httptest.NewRecorder()
		dynamicRelayHandler(w, req)
		io.Copy(io.Discard, w.Result().Body)
		return w.Code
	}

	for _, f := range froms {
		// Public media stays readable by everyone.
		for _, m := range []string{http.MethodGet, http.MethodHead} {
			if got := do(f, m, "/"+posted+".jpg", ""); got != 200 {
				t.Errorf("%s: %s of a publicly posted blob: %d, want 200", f.name, m, got)
			}
		}
		// An unposted blob by exact hash: GET open to everyone (pick B: DM
		// photos, share links, the Android picker), HEAD only to the own app
		// or signed auth so its size and type do not leak.
		if got := do(f, http.MethodGet, "/"+private, ""); got != 200 {
			t.Errorf("%s: unsigned GET of an unposted blob: %d, want 200", f.name, got)
		}
		if got := do(f, http.MethodGet, "/"+private, signed(nostr.GeneratePrivateKey(), "get", private)); got != 200 {
			t.Errorf("%s: stranger-signed GET of an unposted blob: %d, want 200", f.name, got)
		}
		wantHead := 404
		if f.ownApp {
			wantHead = 200
		}
		if got := do(f, http.MethodHead, "/"+private, ""); got != wantHead {
			t.Errorf("%s: unsigned HEAD of an unposted blob: %d, want %d", f.name, got, wantHead)
		}
		// Every suffix khatru still routes to its HEAD handler (Tron).
		for _, suffix := range []string{".", ".jpg", ".jpg.png", ".j-p", ".tar.gz"} {
			if got := do(f, http.MethodHead, "/"+private+suffix, ""); got != wantHead {
				t.Errorf("%s: unsigned HEAD of an unposted blob%s: %d, want %d", f.name, suffix, got, wantHead)
			}
		}
		if got := do(f, http.MethodHead, "/"+private, signed(sk, "get", private)); got != 200 {
			t.Errorf("%s: owner-signed HEAD of an unposted blob: %d, want 200", f.name, got)
		}
		if got := do(f, http.MethodHead, "/"+private, signed(nostr.GeneratePrivateKey(), "get", private)); got != wantHead {
			t.Errorf("%s: stranger-signed HEAD of an unposted blob: %d, want %d", f.name, got, wantHead)
		}

		// /list: only the own app, or the owner's signed list.
		wantList := 401
		if f.ownApp {
			wantList = 200
		}
		if got := do(f, http.MethodGet, "/list/"+pk, ""); got != wantList {
			t.Errorf("%s: unsigned /list: %d, want %d", f.name, got, wantList)
		}
		if got := do(f, http.MethodGet, "/list/"+pk, signed(sk, "list", "")); got != 200 {
			t.Errorf("%s: owner-signed /list: %d, want 200", f.name, got)
		}
		if f.ownApp {
			continue
		}
		if got := do(f, http.MethodGet, "/list/"+pk, signed(nostr.GeneratePrivateKey(), "list", "")); got != 401 {
			t.Errorf("%s: stranger-signed /list: %d, want 401", f.name, got)
		}
	}

	// Over the mesh door the door's own rules still apply (mesh_safety.go);
	// a mesh peer arrives on loopback but is never the own app.
	mesh := httptest.NewServer(http.HandlerFunc(meshHandler))
	defer mesh.Close()
	resp, err := http.Get(mesh.URL + "/" + private)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Errorf("mesh stranger GET of an unposted blob: %d, want 404", resp.StatusCode)
	}
}

// The iPhone's own-device port is reached only over the mesh, and any app on
// the phone can dial it: it is never the own app (review item 10).
func TestRelayPortBlobGateOwnPortIsNotOwnApp(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/"+blobHash('e'), nil)
	req.RemoteAddr = "127.0.0.1:50000"
	req.Host = "127.0.0.1:3355"
	if !relayOwnApp(req) {
		t.Fatal("plain loopback request should be the own app")
	}
	req = req.WithContext(context.WithValue(req.Context(), meshOwnPortKey{}, true))
	if relayOwnApp(req) {
		t.Error("own-device port request taken as the own app")
	}
	req = markMesh(httptest.NewRequest(http.MethodGet, "/"+blobHash('e'), nil))
	req.RemoteAddr = "127.0.0.1:50000"
	req.Host = "127.0.0.1:3355"
	if relayOwnApp(req) {
		t.Error("mesh door request taken as the own app")
	}
}
