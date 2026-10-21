package test

// Upstream defines these in its db_test.go, which can't build for wasm (lmdb,
// postgres, sqlite), so they live here, untagged, for both builds.

import (
	"context"
	"testing"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/eventstore/slicestore"
)

const (
	sk3 = "0000000000000000000000000000000000000000000000000000000000000003"
	sk4 = "0000000000000000000000000000000000000000000000000000000000000004"
)

var ctx = context.Background()

var tests = []struct {
	name string
	run  func(*testing.T, eventstore.Store)
}{
	{"first", runFirstTestOn},
	{"second", runSecondTestOn},
	{"manyauthors", manyAuthorsTest},
	{"unbalanced", unbalancedTest},
}

// Control: the same suite on upstream's in-memory store, in the same browser
// build, so a failure here is the suite or the build, not IndexedDB.
func TestSliceStore(t *testing.T) {
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) { test.run(t, &slicestore.SliceStore{}) })
	}
}
