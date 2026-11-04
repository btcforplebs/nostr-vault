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

// ListHistoryScanStatusC: "" (no scan this import), "scanning", or the scan's
// closing line ("Found 12 older versions of your lists.").
//
//export ListHistoryScanStatusC
func ListHistoryScanStatusC() *C.char {
	return C.CString(ListHistoryScanStatus())
}
