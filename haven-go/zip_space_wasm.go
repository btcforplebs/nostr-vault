//go:build js && wasm

package main

// freeBytes: the browser build has no filesystem to measure.
func freeBytes(string) (uint64, bool) { return 0, false }
