//go:build js && wasm

package main

import (
	"syscall/js"
	"testing"
)

// isolateTestStores gives each test fresh databases. Under node they are
// in-memory already. In a browser they are IndexedDB databases that outlive
// the test (and chrome_exec's reload), and there is no filesystem for
// t.TempDir, so the route databases are deleted instead.
func isolateTestStores(t *testing.T) {
	if runningUnderNode() {
		return
	}
	for _, name := range []string{"private", "chat", "outbox", "inbox", "blossom", "feed"} {
		done := make(chan string, 1)
		req := js.Global().Get("indexedDB").Call("deleteDatabase", "haven:"+name)
		var cbs []js.Func
		for ev, outcome := range map[string]string{"onsuccess": "", "onerror": "error", "onblocked": "blocked"} {
			f := js.FuncOf(func(js.Value, []js.Value) any { done <- outcome; return nil })
			cbs = append(cbs, f)
			req.Set(ev, f)
		}
		outcome := <-done
		for _, f := range cbs {
			f.Release()
		}
		if outcome != "" {
			t.Fatalf("deleting haven:%s: %s", name, outcome)
		}
	}
}
