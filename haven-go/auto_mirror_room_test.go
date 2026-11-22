//go:build !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// Tron #2386: a download is capped while it is read, so a server that
// sends more than the room (with no Content-Length, or a false one) puts
// at most room+1 bytes on disk, and a stated size over the room is refused
// before the body is read.
func TestAutoMirrorDownloadCappedWhileRead(t *testing.T) {
	allowLoopback(t)
	const room = 64 << 10
	var sent atomic.Int64
	big := strings.Repeat("x", 32<<10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		if r.URL.Path == "/stated.jpg" {
			w.Header().Set("Content-Length", "10000000")
			w.WriteHeader(http.StatusOK)
			return
		}
		// Chunked: no Content-Length, 300 chunks (~9.6 MB) unless the reader stops.
		fl := w.(http.Flusher)
		for i := 0; i < 300; i++ {
			n, err := w.Write([]byte(big))
			sent.Add(int64(n))
			if err != nil {
				return
			}
			fl.Flush()
		}
	}))
	defer srv.Close()

	v := &memVault{stored: map[string]string{}}
	f := newFakeBlossom(t)
	d := v.deps(t, f, strings.Repeat("11", 32))
	d.client = srv.Client()
	d.room = func() int64 { return room }

	for _, p := range []string{"/chunked.jpg", "/stated.jpg"} {
		_, err := fetchIntoVault(context.Background(), d, autoMirrorJob{pubkey: strings.Repeat("11", 32), url: srv.URL + p})
		if err != errNoRoom {
			t.Fatalf("%s: err %v, want errNoRoom", p, err)
		}
	}
	if len(v.stored) != 0 {
		t.Fatalf("an over-size file was stored: %v", v.stored)
	}
	left, _ := os.ReadDir(d.tempDir)
	for _, e := range left {
		if strings.HasPrefix(e.Name(), ".auto-mirror-") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}
	// The reader stopped near the cap; the server did not get to send it all
	// (socket buffers let some MB through, never the whole body).
	if s := sent.Load(); s >= 300*int64(len(big)) {
		t.Fatalf("the whole %d byte body was read", s)
	}

	// No room at all: nothing is fetched.
	d.room = func() int64 { return 0 }
	if _, err := fetchIntoVault(context.Background(), d, autoMirrorJob{pubkey: strings.Repeat("11", 32), url: srv.URL + "/chunked.jpg"}); err != errNoRoom {
		t.Fatalf("no room: err %v", err)
	}
}

func TestDownloadRoom(t *testing.T) {
	const gb = 1 << 30
	for _, c := range []struct {
		free  uint64
		known bool
		want  int64
	}{
		{0, false, maxBlobBytes},
		{autoMirrorHeadroom, true, 0},
		{autoMirrorHeadroom + 4*1000, true, 1000}, // a quarter each for the 4 at once
		{100 * gb, true, maxBlobBytes},
	} {
		if got := downloadRoom(c.free, c.known); got != c.want {
			t.Errorf("downloadRoom(%d, %v) = %d, want %d", c.free, c.known, got, c.want)
		}
	}
}

// Tron #2386 low 1: a file already stored (another account's copy) that is
// on this account's server list gets this account's record, with no download.
func TestAutoMirrorClaimsStoredFile(t *testing.T) {
	allowLoopback(t)
	f := newFakeBlossom(t)
	a, b := strings.Repeat("11", 32), strings.Repeat("22", 32)
	shared := []byte("both accounts uploaded this")
	f.blobs[shaOf(shared)] = shared
	v := &memVault{stored: map[string]string{shaOf(shared): b}}
	d := v.deps(t, f, a)
	res := runAutoMirror(context.Background(), d)
	if !v.owners[a+shaOf(shared)] || res.Saved != 1 {
		t.Fatalf("no record added for a: %+v %v", res, v.owners)
	}
	if f.hitsOn("/"+shaOf(shared)) != 0 {
		t.Fatal("a stored file was downloaded again")
	}
	if res = runAutoMirror(context.Background(), d); res.Saved != 0 {
		t.Fatalf("run 2 claimed again: %+v", res)
	}
}
