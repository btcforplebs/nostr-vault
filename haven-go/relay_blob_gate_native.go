//go:build !(js && wasm)

package main

import "net/http"

// Natively: from loopback, no Cloudflare tunnel headers, and every proxy hop
// named is loopback too (the same test as /copy/v2, copyv2_server.go).
func init() {
	relayFromThisMachine = func(r *http.Request) bool { return !copyThroughTunnel(r) && copyFromLoopback(r) }
}
