//go:build cshared

package main

import "C"

import "encoding/json"

// CopyHeldPeersC: the paired devices this one copied from (copyv2_nudge.go),
// as a JSON array of mesh npubs. The app keeps catching up with them even
// when it never read the first copy's done line. The caller frees the string.
//
//export CopyHeldPeersC
func CopyHeldPeersC() *C.char {
	raw, _ := json.Marshal(copyHeldPeers())
	return C.CString(string(raw))
}
