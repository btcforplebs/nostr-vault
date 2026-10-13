package main

import (
	"context"
	"testing"
)

// Resets the session table and returns a live session filed as the active
// signer `active`.
func seedActiveSession(t *testing.T, active string) *nip46Session {
	t.Helper()
	nip46Mu.Lock()
	defer nip46Mu.Unlock()
	for _, s := range nip46Sessions {
		s.cancel()
	}
	nip46Sessions = map[string]*nip46Session{}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s := &nip46Session{ctx: ctx, cancel: cancel, userPubkey: "user-" + active, signer: active}
	nip46Sessions[active] = s
	nip46Active = active
	nip46ActiveGen = 7
	return s
}

func activeSigner() (string, uint64) {
	nip46Mu.RLock()
	defer nip46Mu.RUnlock()
	return nip46Active, nip46ActiveGen
}

// The owner's bunker connected in the background (another account is active)
// gets a session the owner's AUTH can sign through, and the active account's
// signer stays the active one throughout.
func TestNip46BackgroundLoginLeavesTheActiveSignerActive(t *testing.T) {
	seedActiveSession(t, "active-signer")

	live, gen := nip46ClaimLogin("owner-signer", true)
	if live != nil {
		t.Fatalf("no owner session yet, got %+v", live)
	}
	if a, g := activeSigner(); a != "active-signer" || g != 7 || gen != 7 {
		t.Fatalf("background claim moved the active signer: active=%q gen=%d claimGen=%d", a, g, gen)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	owner := &nip46Session{ctx: ctx, cancel: cancel, userPubkey: "owner", signer: "owner-signer"}
	if nip46StoreSession("owner-signer", owner, gen) {
		t.Fatal("a background login must not report itself active")
	}
	if a, g := activeSigner(); a != "active-signer" || g != 7 {
		t.Fatalf("background store moved the active signer: active=%q gen=%d", a, g)
	}
	nip46Mu.RLock()
	stored, bothLive := nip46Sessions["owner-signer"], nip46Sessions["active-signer"] != nil
	nip46Mu.RUnlock()
	if stored != owner || !bothLive {
		t.Fatalf("expected both sessions filed, owner=%v activeKept=%v", stored == owner, bothLive)
	}
}

// Connecting a signer that already has a live session in the background is a
// no-op: the same session comes back and nothing is dropped.
func TestNip46BackgroundLoginReusesALiveSession(t *testing.T) {
	seedActiveSession(t, "active-signer")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	owner := &nip46Session{ctx: ctx, cancel: cancel, userPubkey: "owner", signer: "owner-signer"}
	nip46StoreSession("owner-signer", owner, 7)

	live, _ := nip46ClaimLogin("owner-signer", true)
	if live != owner {
		t.Fatalf("expected the live owner session back, got %+v", live)
	}
	if owner.ctx.Err() != nil {
		t.Fatal("the live session was cancelled by a no-op login")
	}
	if a, _ := activeSigner(); a != "active-signer" {
		t.Fatalf("active signer changed to %q", a)
	}
}

// A dead session (its context is done) does not count as live: a background
// login drops it and logs in again.
func TestNip46BackgroundLoginReplacesADeadSession(t *testing.T) {
	seedActiveSession(t, "active-signer")
	ctx, cancel := context.WithCancel(context.Background())
	dead := &nip46Session{ctx: ctx, cancel: cancel, userPubkey: "owner", signer: "owner-signer"}
	nip46StoreSession("owner-signer", dead, 7)
	cancel()

	live, _ := nip46ClaimLogin("owner-signer", true)
	if live != nil {
		t.Fatalf("a dead session must not be reused, got %+v", live)
	}
	nip46Mu.RLock()
	_, still := nip46Sessions["owner-signer"]
	nip46Mu.RUnlock()
	if still {
		t.Fatal("the dead session is still filed")
	}
}

// The account switched to logs in in the foreground: it claims the active
// slot, and its finished login reports itself active.
func TestNip46ForegroundLoginTakesTheActiveSlot(t *testing.T) {
	seedActiveSession(t, "active-signer")

	live, gen := nip46ClaimLogin("new-signer", false)
	if live != nil {
		t.Fatalf("unexpected live session %+v", live)
	}
	if a, g := activeSigner(); a != "new-signer" || g != 8 || gen != 8 {
		t.Fatalf("foreground claim: active=%q gen=%d claimGen=%d", a, g, gen)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if !nip46StoreSession("new-signer", &nip46Session{ctx: ctx, cancel: cancel, signer: "new-signer"}, gen) {
		t.Fatal("a foreground login nobody moved past must be active")
	}
	// A login that finishes after the user moved on is kept but not active.
	_, gen2 := nip46ClaimLogin("late-signer", false)
	nip46ClaimLogin("other-signer", false)
	ctx2, cancel2 := context.WithCancel(context.Background())
	t.Cleanup(cancel2)
	if nip46StoreSession("late-signer", &nip46Session{ctx: ctx2, cancel: cancel2, signer: "late-signer"}, gen2) {
		t.Fatal("a login finishing after another activation must not take over")
	}
}
