//go:build cshared

package main

import "C"

// RankPullC: one rank pull from the paired Mac or box peer (its mesh npub)
// through base, with no first copy (copyv2_rank_only.go). startAuth: base64
// of the kind 27235 for POST <base>/copy/v2/rank-start, signed by this
// device's mesh key with p = peer; used only when no held token works. Ends
// with a `RANK_PULLED peer=<npub> got=<n>[ error=<code>]` line. 0 started,
// 2 busy, 3 relay not running.
//
//export RankPullC
func RankPullC(peer *C.char, base *C.char, startAuth *C.char) C.int {
	c := relayLC.current.Load()
	if c == nil || c.server == nil {
		return runRelayNotReady
	}
	return C.int(startRankPull(c.ctx, c.spawn, C.GoString(peer), C.GoString(base), C.GoString(startAuth)))
}
