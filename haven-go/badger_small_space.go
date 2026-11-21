//go:build !wasm

package main

import (
	"os"
	"strconv"
	"strings"
)

// A 32-bit phone (budget Samsungs on Android Go) gives the whole app 3 to 4
// GB of address space, shared by the Go heap, the Java heap and every file
// Badger maps. Badger maps each table and each old value-log file at its
// size, and the one value-log file it is writing at twice the configured
// size, per store, across nine stores. A 64-bit phone never notices; a
// 32-bit one runs out of room to map long before it runs out of disk, and a
// map or a heap growth that fails there ends the app (2026-11-21, a 2 GB
// Samsung that crashed on every open until its data was cleared).
//
// So a 32-bit build keeps the value-log files smaller and gathers fewer of
// them before a store is tidied. Nothing here changes a 64-bit build.
var smallAddressSpace = strconv.IntSize == 32 // a var for the tests

const (
	// smallSpaceVlogFileSize: 8 MiB files, so the file being written maps 16
	// MiB per store instead of 32. Safe on a store written with bigger
	// files: Badger maps an existing file at its own size and only sizes new
	// ones from this (third_party/badger/value.go, z.OpenMmapFileUsing).
	// The memtable size is NOT lowered with it: that bricks a store that
	// holds data (see init_badger.go).
	smallSpaceVlogFileSize = 8 << 20
	// smallSpaceTidyMaxVlogs: every open leaves one more value-log file, and
	// each one is another map. 24 instead of badgerTidyMaxVlogs' 256.
	smallSpaceTidyMaxVlogs = 24
	// smallSpaceTidyThinVlog: at the lower count a store is only tidied
	// while its files average under this, which is what files left by opens
	// look like. A store that simply holds that many full files would
	// otherwise be copied on every open and come out with as many.
	smallSpaceTidyThinVlog = smallSpaceVlogFileSize / 2
)

// needsTidy says whether a store with this many value-log files, holding
// vlogBytes between them, is copied before it opens (badger_tidy.go).
func needsTidy(vlogs int, vlogBytes int64) bool {
	if vlogs > badgerTidyMaxVlogs {
		return true
	}
	if !smallAddressSpace || vlogs <= smallSpaceTidyMaxVlogs {
		return false
	}
	return vlogBytes/int64(vlogs) < smallSpaceTidyThinVlog
}

// vlogBytes sums the sizes of the value-log files in dir.
func vlogBytes(dir string) int64 {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var n int64
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".vlog") {
			continue
		}
		if info, err := e.Info(); err == nil {
			n += info.Size()
		}
	}
	return n
}
