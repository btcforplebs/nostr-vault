//go:build !wasm

package main

import (
	"runtime"
	"strings"

	badgerdb "github.com/dgraph-io/badger/v4"
	badgeropts "github.com/dgraph-io/badger/v4/options"
	"github.com/fiatjaf/eventstore/badger"
)

// Badger memory-maps its memtables and value logs, which js/wasm cannot do
// (os.File mmap is "not implemented on js"), so it is native-only; the wasm
// build falls back to memstore_wasm.go instead.
const fallbackBackendName = "Badger"

func fallbackBackend(path string) DBBackend { return newBadgerBackend(path) }

// quietBadgerLogger wraps Badger's logger to drop the once-a-minute cache-size
// warnings. The block/index caches are intentionally kept small here (see the
// BadgerOptionsModifier below) to fit a menu-bar app, so the "might be too
// small" warning and its companion "Cache life expectancy" histogram — emitted
// every 60s per DB by (*badger.DB).monitorCache — are expected noise, not
// actionable. Every other Badger log line (real warnings, errors, info) passes
// through untouched.
type quietBadgerLogger struct{ badgerdb.Logger }

func (l quietBadgerLogger) Warningf(format string, args ...interface{}) {
	if strings.Contains(format, "might be too small") ||
		strings.Contains(format, "Cache life expectancy") {
		return
	}
	l.Logger.Warningf(format, args...)
}

func newBadgerBackend(path string) DBBackend {
	// Bound the negentropy vector size explicitly: the library default is 16M
	// events, which a NEG-OPEN with a broad filter could try to materialize in
	// memory — far too much on a phone.
	maxNeg := 100_000
	if runtime.GOOS == "android" || runtime.GOOS == "ios" {
		maxNeg = 50_000
	}
	return &badger.BadgerBackend{
		Path:               path,
		MaxLimitNegentropy: maxNeg,
		BadgerOptionsModifier: func(opts badgerdb.Options) badgerdb.Options {
			// Silence Badger's every-60s cache-size warnings; the small caches
			// below are deliberate. Wraps whatever logger Badger defaulted to.
			opts = opts.WithLogger(quietBadgerLogger{opts.Logger})
			switch runtime.GOOS {
			case "android", "ios":
				// Phones share RAM with the JVM (Android) or live under strict
				// jetsam limits (iOS). With 6 databases running, every MB
				// counts. These settings target ~20-26 MB per DB (vs ~60-80 MB
				// server defaults):
				//   - 16 MiB vlog files (vs 2 GB default)
				//   - 2 memtables (vs 5): allows 1 flush in background without stalling writes
				//   - Fewer L0 tables: reduces open file handles and mmap
				//   - 2 compactor threads (vs 4): fewer goroutines (BadgerDB requires >= 2)
				//   - No compression: saves CPU cycles
				//   - Small block/index caches: avoids disk reads for hot data
				return opts.
					WithMemTableSize(8 << 20).        // 8 MiB (default 64 MiB)
					WithValueLogFileSize(1 << 24).    // 16 MiB
					WithNumMemtables(2).              // default 5; allows 1 background flush
					WithNumLevelZeroTables(1).        // default 5
					WithNumLevelZeroTablesStall(2).   // default 15
					WithNumCompactors(2).             // default 4, minimum 2
					WithCompression(badgeropts.None). // disable compression (saves CPU)
					WithBlockCacheSize(4 << 20).      // 4 MiB per DB (20 MiB total across 5 DBs)
					WithIndexCacheSize(2 << 20).      // 2 MiB per DB (10 MiB total across 5 DBs)
					WithValueThreshold(1 << 10)       // 1 KB: inline small values
			default:
				// macOS / desktop: the server defaults are far too hungry for a
				// menu-bar app — each memtable arena is a 64 MiB up-front
				// allocation and the block-cache budget is 256 MiB, per DB,
				// across 6 DBs. Desktop can afford more than a phone but not
				// server sizing.
				return opts.
					// DO NOT SHRINK on an existing database. Badger sizes the
					// skiplist arena from MemTableSize and replays each existing
					// .mem WAL into it at open; a WAL written under a larger
					// setting overflows the smaller arena and trips
					// y.AssertTruef("Arena too small") inside Open — the relay
					// dies mid-DB-load with no recoverable error. Lowering this
					// 16→8 MiB shipped in b12 and bricked a populated relay on
					// first launch (boots, opens private/chat/outbox, dies
					// before inbox). Raising it is safe; lowering needs a
					// migration that flushes every memtable first.
					WithMemTableSize(16 << 20).       // 16 MiB (default 64 MiB, allocated up-front per DB)
					WithValueLogFileSize(1 << 26).    // 64 MiB (default ~1 GiB, mmap'd)
					WithNumMemtables(2).              // default 5; allows 1 background flush
					WithNumLevelZeroTables(2).        // default 5
					WithNumLevelZeroTablesStall(4).   // default 15
					WithNumCompactors(2).             // default 4, minimum 2
					WithCompression(badgeropts.None). // disable compression (saves CPU)
					WithBlockCacheSize(32 << 20).     // 32 MiB per DB (default 256 MiB)
					WithIndexCacheSize(8 << 20).      // 8 MiB per DB (default unbounded shared with heap)
					WithValueThreshold(1 << 10)       // 1 KB: inline small values
			}
		},
	}
}
