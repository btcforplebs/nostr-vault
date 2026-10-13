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
	if nip46StoreSession("owner-signer", owner, gen, true) {
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
	nip46StoreSession("owner-signer", owner, 7, true)

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
	nip46StoreSession("owner-signer", dead, 7, true)
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
	if !nip46StoreSession("new-signer", &nip46Session{ctx: ctx, cancel: cancel, signer: "new-signer"}, gen, false) {
		t.Fatal("a foreground login nobody moved past must be active")
	}
	// A login that finishes after the user moved on is kept but not active.
	_, gen2 := nip46ClaimLogin("late-signer", false)
	nip46ClaimLogin("other-signer", false)
	ctx2, cancel2 := context.WithCancel(context.Background())
	t.Cleanup(cancel2)
	if nip46StoreSession("late-signer", &nip46Session{ctx: ctx2, cancel: cancel2, signer: "late-signer"}, gen2, false) {
		t.Fatal("a login finishing after another activation must not take over")
	}
}

// The owner and the active account share one bunker host (Clave-style). A
// background owner login that started before the switch and lands after the
// active account's foreground login must not cancel the session the active
// account is signing through: the foreground session stays, the newcomer is
// closed.
func TestNip46BackgroundLoginNeverReplacesALiveSession(t *testing.T) {
	seedActiveSession(t, "other-signer")
	const host = "shared-host"

	_, bgGen := nip46ClaimLogin(host, true)  // background login starts…
	_, fgGen := nip46ClaimLogin(host, false) // …then the user switches to the account on this host
	fgCtx, fgCancel := context.WithCancel(context.Background())
	t.Cleanup(fgCancel)
	fg := &nip46Session{ctx: fgCtx, cancel: fgCancel, userPubkey: "active", signer: host}
	if !nip46StoreSession(host, fg, fgGen, false) {
		t.Fatal("the foreground login is the active session")
	}

	bgCtx, bgCancel := context.WithCancel(context.Background())
	bg := &nip46Session{ctx: bgCtx, cancel: bgCancel, userPubkey: "owner", signer: host}
	if nip46StoreSession(host, bg, bgGen, true) {
		t.Fatal("a background login must not report itself active")
	}
	nip46Mu.RLock()
	filed, active := nip46Sessions[host], nip46Active
	nip46Mu.RUnlock()
	if filed != fg || fg.ctx.Err() != nil {
		t.Fatalf("the live foreground session was replaced or cancelled (filed==fg=%v, fgErr=%v)", filed == fg, fg.ctx.Err())
	}
	if bg.ctx.Err() == nil {
		t.Fatal("the losing background session must be closed")
	}
	if active != host {
		t.Fatalf("active signer moved to %q", active)
	}
}

// A background login landing on the active key (its session had died, so the
// claim dropped it) files the session but still does not call itself active.
func TestNip46BackgroundLoginOnTheActiveKeyIsNotReportedActive(t *testing.T) {
	s := seedActiveSession(t, "active-signer")
	s.cancel()
	live, gen := nip46ClaimLogin("active-signer", true)
	if live != nil {
		t.Fatal("a dead session must not be reused")
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if nip46StoreSession("active-signer", &nip46Session{ctx: ctx, cancel: cancel, signer: "active-signer"}, gen, true) {
		t.Fatal("a background login never reports itself active")
	}
}
