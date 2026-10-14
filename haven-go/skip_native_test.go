//go:build !(js && wasm)

package main

import "testing"

// Native builds have sockets and a filesystem: never skip.
// See skip_wasm_test.go.
func skipWithoutSockets(*testing.T) {}
func skipWithoutFS(*testing.T)      {}
