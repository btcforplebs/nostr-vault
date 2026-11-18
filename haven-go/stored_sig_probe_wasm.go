//go:build wasm

package main

// mayHoldID: the web build keeps no id set, and its stores are IndexedDB
// (store_wasm.go), where a lookup per event in the read loop would cost IDB
// transactions before the verify. So the web never skips: every event is
// verified as before.
func (g *gatedDB) mayHoldID(id string) bool { return false }
