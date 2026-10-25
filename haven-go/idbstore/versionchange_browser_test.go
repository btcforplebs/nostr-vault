//go:build js && wasm

package idbstore_test

import (
	"context"
	"syscall/js"
	"testing"
	"time"

	"github.com/barrydeen/haven/idbstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/stretchr/testify/require"
)

// TestVersionChange: a newer build opening the same database at a higher
// version must not sit blocked behind a tab still on the old one. The open
// store closes and says so on the global scope, so the page can reload.
func TestVersionChange(t *testing.T) {
	name := "idbstore-versionchange-test"
	deleteDB(t, name)
	defer deleteDB(t, name)

	db := &idbstore.IDBBackend{Name: name}
	require.NoError(t, db.Init())
	require.NoError(t, db.SaveEvent(context.Background(), &nostr.Event{
		ID: "0000000000000000000000000000000000000000000000000000000000000001", PubKey: "0000000000000000000000000000000000000000000000000000000000000002",
		CreatedAt: 1, Kind: 1, Tags: nostr.Tags{}, Content: "kept", Sig: "00",
	}))

	heard := make(chan struct{}, 1)
	onEvent := js.FuncOf(func(js.Value, []js.Value) any { heard <- struct{}{}; return nil })
	defer onEvent.Release()
	js.Global().Call("addEventListener", idbstore.VersionChangeEvent, onEvent)
	defer js.Global().Call("removeEventListener", idbstore.VersionChangeEvent, onEvent)

	opened, blocked := make(chan js.Value, 1), make(chan struct{}, 1)
	req := js.Global().Get("indexedDB").Call("open", name, 2)
	onSuccess := js.FuncOf(func(js.Value, []js.Value) any { opened <- req.Get("result"); return nil })
	onBlocked := js.FuncOf(func(js.Value, []js.Value) any { blocked <- struct{}{}; return nil })
	defer onSuccess.Release()
	defer onBlocked.Release()
	req.Set("onsuccess", onSuccess)
	req.Set("onblocked", onBlocked)

	select {
	case newer := <-opened:
		require.Equal(t, 2, newer.Get("version").Int())
		newer.Call("close")
	case <-blocked:
		// Let the newer open through, or the deferred delete would queue behind it for good.
		db.Close()
		(<-opened).Call("close")
		t.Fatal("the newer open was blocked by the open store")
	case <-time.After(5 * time.Second):
		t.Fatal("the newer open never finished")
	}
	select {
	case <-heard:
	case <-time.After(time.Second):
		t.Fatalf("no %s event", idbstore.VersionChangeEvent)
	}
}
