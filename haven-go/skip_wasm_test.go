//go:build js && wasm

package main

import "testing"

// js/wasm has no sockets, in node or in a browser: the net package's dials
// and listens fail ("use of closed network connection"), so a test that
// starts httptest.NewServer or dials ws://127.0.0.1 can't run here.
func skipWithoutSockets(t *testing.T) {
	t.Helper()
	t.Skip("needs sockets: js/wasm has none")
}

// A browser page has no filesystem (t.TempDir and t.Chdir report "not
// implemented on js"). Node has one, so these tests still run there.
func skipWithoutFS(t *testing.T) {
	t.Helper()
	if !runningUnderNode() {
		t.Skip("needs a filesystem: a browser page has none")
	}
}
