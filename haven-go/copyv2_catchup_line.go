//go:build !(js && wasm)

package main

import "log/slog"

// endLine logs a catch-up's end and prints its COPY line (§3.3). The apps
// stamp a catch-up, and clear the one they show running, from that line
// (Tron, #2480): without it the time never moved and iOS kept the run "on"
// for the whole relay session.
func (c *copyClient) endLine(res copySyncResult, err error) {
	if err != nil {
		slog.Warn("copy catch-up stopped", "error", copyErrorCode(err))
		c.line(copyLine{Stage: "failed", Error: copyErrorCode(err)})
		return
	}
	n := int64(res.Got + res.Files)
	c.line(copyLine{Stage: "done", Items: [2]int64{n, n}})
}
