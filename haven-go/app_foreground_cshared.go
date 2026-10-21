//go:build cshared

package main

import "C"

//export SetAppForegroundC
func SetAppForegroundC(on C.int) {
	// The host app calls this when it comes on screen (1) and when it leaves
	// it (0). Until it first does, the relay treats the app as on screen.
	appForeground.set(on != 0)
}
