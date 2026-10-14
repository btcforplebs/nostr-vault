//go:build !(js && wasm)

package main

import "testing"

// isolateTestStores gives each test fresh databases: Badger and LMDB live
// under the working directory.
func isolateTestStores(t *testing.T) { t.Chdir(t.TempDir()) }
