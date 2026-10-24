//go:build js && wasm

package idbstore

// CursorVisits is how many records queries have visited so far.
func CursorVisits() int { return cursorVisits }
