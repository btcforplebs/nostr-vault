//go:build !(js && wasm)

package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The live wiring on a real vault: Auto-Mirror reads the account's 10063 and
// notes from the store, stores files as the account with no signature, and
// Copy to servers then finds a file a server lacks and uploads the vault's
// own copy with the caller's auth, all through the request/state files the
// box writes and reads.
func TestMediaJobsOnARealVault(t *testing.T) {
	k := newCopyKey(t)
	openCopyVault(t, k.pk)
	allowLoopback(t)
	oldFs := fs
	fs = newRootFs() // as main does; forwardOnce reads the stored file through it
	t.Cleanup(func() { fs = oldFs })

	var mu sync.Mutex
	remote := map[string][]byte{}  // what the outside server holds
	uploads := map[string]string{} // sha -> Authorization
	photo := []byte("a photo only on the outside server")
	clip := []byte("a clip linked from a note by name")
	remote[shaOf(photo)] = photo
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		p := strings.TrimPrefix(r.URL.Path, "/")
		switch {
		case r.Method == http.MethodGet && strings.HasPrefix(p, "list/"):
			out := []blobListEntry{}
			for sha := range remote {
				out = append(out, blobListEntry{SHA256: sha})
			}
			json.NewEncoder(w).Encode(out)
		case r.Method == http.MethodGet && p == "clip.mp4":
			w.Header().Set("Content-Type", "video/mp4")
			w.Write(clip)
		case r.Method == http.MethodPut && p == "upload":
			b, _ := io.ReadAll(r.Body)
			remote[shaOf(b)] = b
			uploads[shaOf(b)] = r.Header.Get("Authorization")
		case (r.Method == http.MethodGet || r.Method == http.MethodHead) && remote[p] != nil:
			w.Header().Set("Content-Type", "image/jpeg")
			w.Write(remote[p])
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	oldJobs, oldFwd := mediaJobsClient, forwardClient
	mediaJobsClient, forwardClient = srv.Client(), srv.Client()
	t.Cleanup(func() { mediaJobsClient, forwardClient = oldJobs, oldFwd })

	ctx := context.Background()
	save := func(ev nostr.Event) {
		if err := ev.Sign(k.sk); err != nil {
			t.Fatal(err)
		}
		if err := outboxDB.SaveEvent(ctx, &ev); err != nil {
			t.Fatal(err)
		}
	}
	save(nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"server", srv.URL + "/"}, {"server", "http://plain.example"}}})
	save(nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "new clip " + srv.URL + "/clip.mp4"})

	if got := accountServers(ctx, k.pk); len(got) != 1 || got[0] != srv.URL {
		t.Fatalf("servers from the 10063: %v (https only, no trailing slash)", got)
	}

	// The box turns it on; one tick runs it.
	writeJSONFile(autoMirrorSettingsFile, autoMirrorSettings{Enabled: true})
	autoMirrorTick(ctx, time.Now, liveAutoMirrorDeps)
	var st autoMirrorState
	if !readJSONFile(autoMirrorStateFile, &st) || st.Last == nil || st.Last.Saved != 2 {
		t.Fatalf("auto-mirror state: %+v %+v", st, st.Last)
	}
	own, err := accountOwnFiles(ctx, k.pk)
	if err != nil || len(own) != 2 {
		t.Fatalf("own files: %v %v", own, err)
	}
	if _, ok := own[shaOf(clip)]; !ok || own[shaOf(clip)] != "video/mp4" {
		t.Fatalf("clip stored as the account with its type: %v", own)
	}
	if links := loadAutoMirrorLinks(autoMirrorLinksFile); links.hashFor(srv.URL+"/clip.mp4") != shaOf(clip) {
		t.Fatal("the note link was not remembered")
	}

	// Copy to servers: the clip is only here.
	writeJSONFile(mediaCopyRequestFile, mediaCopyRequest{ID: "c1", Action: "check", Pubkey: k.pk})
	req, ok := takeMediaCopyRequest()
	if !ok {
		t.Fatal("request not taken")
	}
	if _, err := os.Stat(mediaCopyRequestFile); !os.IsNotExist(err) {
		t.Fatal("request left in place")
	}
	var last mediaCopyState
	cs := runMediaCopy(ctx, liveMediaCopyDeps(), req, last)
	if cs.Error != "" || len(cs.Files) != 1 || cs.Files[0].SHA256 != shaOf(clip) {
		t.Fatalf("check: %+v", cs)
	}
	readJSONFile(mediaCopyStateFile, &last)
	auth := k.uploadAuth(t, time.Now(), time.Hour, shaOf(clip))
	writeJSONFile(mediaCopyRequestFile, mediaCopyRequest{ID: "c2", Action: "copy", Pubkey: k.pk, Auths: []string{auth}})
	req, _ = takeMediaCopyRequest()
	cs = runMediaCopy(ctx, liveMediaCopyDeps(), req, last)
	if cs.Copied != 1 || cs.Error != "" {
		t.Fatalf("copy: %+v", cs)
	}
	mu.Lock()
	defer mu.Unlock()
	if string(remote[shaOf(clip)]) != string(clip) || uploads[shaOf(clip)] != "Nostr "+auth {
		t.Fatalf("server got %q with %q", remote[shaOf(clip)], uploads[shaOf(clip)])
	}
}
