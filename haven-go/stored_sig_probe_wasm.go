//go:build wasm

package main

// mayHoldID: the web build keeps no id set (its stores are in memory, and a
// query is already cheap), so every possible copy is read for real.
func (g *gatedDB) mayHoldID(id string) bool { return true }
