//go:build cshared

package main

import "C"

// SkipListHistoryScanC: Moving in's Skip button. Stops the list history scan
// (list_history_scan.go) and keeps the versions found so far; the import
// carries on. 1 when a scan was running.
//
//export SkipListHistoryScanC
func SkipListHistoryScanC() C.int {
	if SkipListHistoryScan() {
		return 1
	}
	return 0
}
