//go:build js && wasm

// The other files in this directory are eventstore v0.17.5's own store test
// suite (github.com/fiatjaf/eventstore/test), copied byte for byte so it can
// run against IDBBackend in a browser. This file and shared_test.go are ours:
// upstream's db_test.go imports lmdb, postgres and sqlite, which can't build
// for wasm.
//
// Run with: GOOS=js GOARCH=wasm go test -exec ./idbstore/harness/chrome_exec ./idbstore/...

package test

import (
	"flag"
	"fmt"
	"os"
	"testing"

	"github.com/barrydeen/haven/idbstore"
)

// TestMain: the harness runs every test binary twice, the second time after a
// page reload. This suite has nothing to check after a reload.
func TestMain(m *testing.M) {
	flag.Parse()
	if os.Getenv("IDBSTORE_PHASE") == "2" {
		fmt.Println("phase 2: this suite has nothing to check after a reload")
		fmt.Println("PASS")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestIDB(t *testing.T) {
	for i, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			test.run(t, &idbstore.IDBBackend{Name: fmt.Sprintf("suite-%d-%s", i, test.name)})
		})
	}
}
