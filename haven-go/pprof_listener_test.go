//go:build !wasm

package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func resetPprofForTest(t *testing.T) {
	t.Helper()
	pprofOnce.Lock()
	if pprofListener != nil {
		pprofListener.Close()
		pprofListener = nil
	}
	pprofOnce.Unlock()
	t.Cleanup(func() {
		pprofOnce.Lock()
		if pprofListener != nil {
			pprofListener.Close()
			pprofListener = nil
		}
		pprofOnce.Unlock()
	})
}

// Off unless HAVEN_PPROF_ADDR is set.
func TestPprofIsOffByDefault(t *testing.T) {
	resetPprofForTest(t)
	t.Setenv(pprofAddrEnv, "")
	started, err := startPprofIfSet()
	if started || err != nil || pprofListener != nil {
		t.Fatalf("pprof started with the setting empty: started=%v err=%v", started, err)
	}
}

// Only 127.0.0.1: never a wildcard, a LAN or IPv6 address, or a name.
func TestPprofRefusesAnythingButLoopbackV4(t *testing.T) {
	for _, raw := range []string{"0.0.0.0:6061", ":6061", "192.168.4.99:6061", "[::]:6061", "[::1]:6061",
		"localhost:6061", "127.0.0.2:6061", "127.0.0.1", "127.0.0.1:x", "127.0.0.1:70000"} {
		resetPprofForTest(t)
		t.Setenv(pprofAddrEnv, raw)
		started, err := startPprofIfSet()
		if err == nil || pprofListener != nil {
			t.Fatalf("%q: listener started (started=%v)", raw, started)
		}
	}
}

// Nothing lands on http.DefaultServeMux, which the standalone relay serves.
func TestPprofNotOnTheDefaultMux(t *testing.T) {
	req, _ := http.NewRequest("GET", "http://x/debug/pprof/goroutine", nil)
	if _, pattern := http.DefaultServeMux.Handler(req); strings.Contains(pattern, "pprof") {
		t.Fatalf("pprof on the default mux: %q", pattern)
	}
}

func TestPprofServesProfilesOnLoopback(t *testing.T) {
	resetPprofForTest(t)
	t.Setenv(pprofAddrEnv, "127.0.0.1:0")
	started, err := startPprofIfSet()
	if !started || err != nil {
		t.Fatalf("not started: %v", err)
	}
	if !strings.HasPrefix(pprofListener.Addr().String(), "127.0.0.1:") {
		t.Fatalf("listening on %s", pprofListener.Addr())
	}
	resp, err := http.Get("http://" + pprofListener.Addr().String() + "/debug/pprof/goroutine?debug=1")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(body), "goroutine profile: total") {
		t.Fatalf("goroutine profile missing: %.200s", body)
	}
	resp, _ = http.Get("http://" + pprofListener.Addr().String() + "/debug/pprof/nope")
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown profile: %d", resp.StatusCode)
	}
	resp.Body.Close()
}
