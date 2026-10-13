//go:build wasm

package main

import "github.com/spf13/afero"

// A browser has no filesystem: wasm_exec.js answers every fs call with
// ENOSYS, so Blossom's MkdirAll at boot would be fatal. Blobs live in memory
// until a browser-persistent store replaces this; nothing survives a reload.
func newRootFs() afero.Fs { return afero.NewMemMapFs() }
