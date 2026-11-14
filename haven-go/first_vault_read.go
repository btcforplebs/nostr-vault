package main

import (
	"time"
)

// The app's first Vault read after a launch goes before background setup
// (Logen 2026-11-14: Vault rows < 0.5 s after a cold tap). Measured on the
// Android emulator (release, 2 cores, 9 launches each, interleaved): with
// background setup (WoT, feed sync, follower ledger, inbox subscriptions,
// import resume) starting in the same second, the first read took 488 ms on
// average and rows showed at 1.73 s; held, 393 ms and 1.28 s. Warming the
// stores first and turning GC off for the window measured no better.

// firstVaultReadHold is the longest background setup waits for the app's
// first Vault read: a host that never reads (a CLI, a Mac with the Vault
// closed) starts it this much later, and nothing else changes.
var firstVaultReadHold = 1500 * time.Millisecond

// markVaultRead records that the app's Vault read answered on this cycle.
func (c *relayCycle) markVaultRead() {
	if c == nil || c.vaultRead == nil {
		return
	}
	c.vaultReadOnce.Do(func() { close(c.vaultRead) })
}

// waitFirstVaultRead blocks until the cycle's first Vault read answered,
// hold passed or the cycle stopped. It reports whether the read came first.
func (c *relayCycle) waitFirstVaultRead(hold time.Duration) bool {
	if c == nil || c.vaultRead == nil {
		return false
	}
	t := time.NewTimer(hold)
	defer t.Stop()
	select {
	case <-c.vaultRead:
		return true
	case <-t.C:
		return false
	case <-c.ctx.Done():
		return false
	}
}

// afterFirstVaultRead wraps fn to start once the cycle's first Vault read
// answered or firstVaultReadHold passed, whichever comes first, unless the
// cycle stopped meanwhile.
func (c *relayCycle) afterFirstVaultRead(fn func()) func() {
	return func() {
		if c.waitFirstVaultRead(firstVaultReadHold) {
			startupMark("background setup after vault read")
		} else {
			startupMark("background setup after hold")
		}
		if c.ctx.Err() != nil {
			return
		}
		fn()
	}
}
