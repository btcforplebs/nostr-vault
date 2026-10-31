//go:build !cshared && !(js && wasm)

package main

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

// The CLI engine (the Linux box) opens the mesh door itself when
// HAVEN_MESH_PLAIN_PORT is set: on loopback only, and closed to everything
// but what the door gives a mesh peer.
func TestCLIMeshDoorOpensFromEnv(t *testing.T) {
	t.Setenv("HAVEN_MESH_PLAIN_PORT", "")
	if srv, err := startMeshDoorFromEnv(); srv != nil || err != nil {
		t.Fatalf("unset: %v %v", srv, err)
	}
	t.Setenv("HAVEN_MESH_PLAIN_PORT", "nope")
	if _, err := startMeshDoorFromEnv(); err == nil {
		t.Fatal("bad port accepted")
	}

	startHaven(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	t.Setenv("HAVEN_MESH_PLAIN_PORT", strconv.Itoa(port))
	srv, err := startMeshDoorFromEnv()
	if err != nil || srv == nil {
		t.Fatalf("door: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	if !strings.HasPrefix(srv.Addr, "127.0.0.1:") {
		t.Fatalf("door on %q, want loopback only", srv.Addr)
	}

	door := "http://127.0.0.1:" + strconv.Itoa(port)
	for _, c := range []struct{ method, path, accept string }{
		{http.MethodGet, "/", ""},
		{http.MethodGet, "/", "application/nostr+json"},
		{http.MethodPost, "/", ""},
		{http.MethodGet, "/private", ""},
		{http.MethodGet, "/api/box/status", ""},
		{http.MethodGet, "/list/" + strings.Repeat("ab", 32), ""},
	} {
		r, _ := http.NewRequest(c.method, door+c.path, nil)
		if c.accept != "" {
			r.Header.Set("Accept", c.accept)
		}
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s %s (accept %q): got %d, want 404", c.method, c.path, c.accept, resp.StatusCode)
		}
	}
	// A blob that is not there is a 404 too: the door is the Blossom read path.
	resp, err := http.Get(door + "/" + strings.Repeat("cd", 32))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("missing blob: %d", resp.StatusCode)
	}
}
