//go:build js && wasm

package main

import (
	"strings"
	"syscall/js"

	"github.com/barrydeen/haven/idbstore"
)

// In a browser (page or worker) every database is an IndexedDB store, one
// per route: "db/private" opens "haven:private". Init opens it and returns
// the IDB error if that fails, so an unusable IndexedDB (private browsing,
// a partitioned context, a quota denial) fails havenStart instead of
// quietly serving from memory and losing everything on reload.
//
// Only node gets the in-memory store: the test suite runs there under
// go_js_wasm_exec. The choice keys on node itself, never on a missing
// indexedDB global.
const fallbackBackendName = "the browser store"

func fallbackBackend(path string) DBBackend {
	if runningUnderNode() {
		return newMemBackend(path)
	}
	return &idbstore.IDBBackend{Name: "haven:" + strings.TrimPrefix(path, "db/")}
}

func runningUnderNode() bool {
	proc := js.Global().Get("process")
	if proc.Type() != js.TypeObject {
		return false
	}
	versions := proc.Get("versions")
	return versions.Type() == js.TypeObject && versions.Get("node").Type() == js.TypeString
}
