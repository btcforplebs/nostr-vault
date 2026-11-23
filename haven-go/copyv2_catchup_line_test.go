//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// catchUpLine runs one catch-up the way the apps start it (CopySyncC) and
// returns the COPY line it printed.
func catchUpLine(t *testing.T, base string) copyLine {
	t.Helper()
	var buf bytes.Buffer
	captureLog(t, &buf)
	run := func(_ string, fn func()) { fn() }
	if rc := startCopySync(context.Background(), run, "npub1peer", base, false); rc != 0 {
		t.Fatalf("catch-up not started: %d", rc)
	}
	var got []copyLine
	for _, raw := range strings.Split(buf.String(), "\n") {
		if l, ok := parseCopyLine(raw); ok {
			got = append(got, l)
		}
	}
	if len(got) != 1 {
		t.Fatalf("want one COPY line, got %d: %q", len(got), buf.String())
	}
	return got[0]
}

// The apps stamp a catch-up and clear the run they show from its end line:
// the engine printed none for a catch-up, so the time never moved once the
// start stopped stamping it (Tron, #2480).
func TestCopyCatchUpPrintsItsDoneLine(t *testing.T) {
	_, _, _, _, url := trustPair(t, 100)
	l := catchUpLine(t, url)
	if l.Stage != "done" || l.Part != "-" || l.Source != "mesh" || l.Error != "" {
		t.Fatalf("end line %+v", l)
	}
}

func TestCopyCatchUpPrintsItsFailedLine(t *testing.T) {
	trustPair(t, 100)
	gone := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "", http.StatusForbidden)
	}))
	t.Cleanup(gone.Close)
	l := catchUpLine(t, gone.URL)
	if l.Stage != "failed" || l.Part != "-" || l.Source != "mesh" || l.Error == "" {
		t.Fatalf("end line %+v", l)
	}
}
