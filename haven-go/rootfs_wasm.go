//go:build js && wasm

package main

import "github.com/spf13/afero"

// A browser has no filesystem: wasm_exec.js answers every fs call with
// ENOSYS, so Blossom's MkdirAll at boot would be fatal. Blobs go to
// IndexedDB, per account (blobfs_wasm.go), so they survive a reload. Only
// node keeps them in memory: the test suite runs there, without IndexedDB.
func newRootFs() afero.Fs {
	if runningUnderNode() {
		return afero.NewMemMapFs()
	}
	return newBlobFs(storeName(storePrefix, "db/blobs"), config.BlossomPath)
}
