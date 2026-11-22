//go:build cshared

package main

import "C"

//export SetTrustRankC
func SetTrustRankC(on C.int) {
	// The Mac app calls this with 1 while "Run in background" is on and its
	// window is closed, and 0 otherwise. The phones never call it, and the
	// crawler never runs there anyway (trustRankWanted).
	trustRankHost.Store(on != 0)
}
