//go:build cshared

package main

import "C"

import (
	"context"

	"github.com/barrydeen/haven/wallet"
)

// The built-in Cashu wallet's C surface (haven-go/wallet/bridge.go). Apple
// calls these directly; Android calls them from its JNI shim
// (HavenBridgeJNI.c, app side). Every function returns JSON the caller
// frees: {"ok":true,"result":…} or {"ok":false,"error":"…","code":"…"}.

// CashuWalletOpenC opens the wallet whose state file is path (absolute, in
// the app's private storage, one per account). Result {"handle":n}. The same
// path gives the same handle; close once per open.
//
//export CashuWalletOpenC
func CashuWalletOpenC(path *C.char) *C.char {
	return C.CString(string(wallet.BridgeOpen(C.GoString(path))))
}

// CashuWalletCallC runs method with args (a JSON object, or empty) on an
// open wallet. Mint calls block up to 2 minutes: call it off the main thread.
//
//export CashuWalletCallC
func CashuWalletCallC(handle C.int, method *C.char, args *C.char) *C.char {
	return C.CString(string(wallet.BridgeCall(context.Background(), int(handle), C.GoString(method), []byte(C.GoString(args)))))
}

// CashuWalletCloseC lets go of one open of handle.
//
//export CashuWalletCloseC
func CashuWalletCloseC(handle C.int) {
	wallet.BridgeClose(int(handle))
}
