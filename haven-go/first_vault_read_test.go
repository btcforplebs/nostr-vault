package main

import (
	"net/http"
	"testing"
	"time"
)

// Background setup waits for the app's first Vault read (first_vault_read.go):
// it starts when the read answered, when the hold passed, and never on a
// stopped cycle.

func closedNow(ch chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

func TestFirstVaultReadReleasesTheWait(t *testing.T) {
	c := newRelayCycle()
	defer c.cancel()
	go func() {
		time.Sleep(20 * time.Millisecond)
		c.markVaultRead()
		c.markVaultRead() // a second answer is a no-op, not a double close
	}()
	start := time.Now()
	if !c.waitFirstVaultRead(5 * time.Second) {
		t.Fatal("the read answered but the wait reported the hold")
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("waited %v for a read that answered at once", waited)
	}
}

func TestFirstVaultReadHoldEnds(t *testing.T) {
	c := newRelayCycle()
	defer c.cancel()
	start := time.Now()
	if c.waitFirstVaultRead(30 * time.Millisecond) {
		t.Fatal("no read answered, yet the wait reported one")
	}
	if waited := time.Since(start); waited < 30*time.Millisecond {
		t.Fatalf("hold ended after %v", waited)
	}
}

func TestFirstVaultReadStopEndsTheWait(t *testing.T) {
	c := newRelayCycle()
	c.cancel()
	start := time.Now()
	if c.waitFirstVaultRead(5 * time.Second) {
		t.Fatal("a stopped cycle reported a read")
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("a stopped cycle still waited %v", waited)
	}
}

func TestBackgroundSetupStartsAfterTheReadAndNeverOnAStop(t *testing.T) {
	prev := firstVaultReadHold
	firstVaultReadHold = 5 * time.Second
	defer func() { firstVaultReadHold = prev }()

	c := newRelayCycle()
	defer c.cancel()
	ran := make(chan struct{})
	go c.afterFirstVaultRead(func() { close(ran) })()
	time.Sleep(50 * time.Millisecond)
	if closedNow(ran) {
		t.Fatal("background setup ran before the read answered")
	}
	c.markVaultRead()
	select {
	case <-ran:
	case <-time.After(2 * time.Second):
		t.Fatal("background setup did not start after the read")
	}

	stopped := newRelayCycle()
	didRun := make(chan struct{})
	done := make(chan struct{})
	go func() {
		stopped.afterFirstVaultRead(func() { close(didRun) })()
		close(done)
	}()
	stopped.cancel()
	<-done
	if closedNow(didRun) {
		t.Fatal("background setup ran on a stopped cycle")
	}
}

// QueryVaultC marks the read only when it answered with rows, not on a bad
// request.
func TestVaultReadAnswerReleasesBackgroundSetup(t *testing.T) {
	skipWithoutSockets(t)
	if relayLC.current.Load() != nil {
		t.Skip("a relay cycle is live in this binary")
	}
	h := startHaven(t)
	c := newRelayCycle()
	c.server = &http.Server{}
	relayLC.current.Store(c)
	defer relayLC.current.Store(nil)
	defer c.cancel()

	queryVault(`{"filters":[`)
	if closedNow(c.vaultRead) {
		t.Fatal("a bad request released background setup")
	}
	queryVault(`{"filters":[{"kinds":[1],"authors":["` + h.owner + `"]}]}`)
	if !closedNow(c.vaultRead) {
		t.Fatal("an answered read did not release background setup")
	}
}
