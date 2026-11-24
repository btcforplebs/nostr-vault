package box

import (
	"context"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Tron's #2502 review: a pairing run belongs to the account that started
// it; the seed trusts the lists when every one is known; a role clash is
// told at the hello; an ack no relay took is a failure.

func TestBoxPairingRunBelongsToTheAccountThatStartedIt(t *testing.T) {
	srv, owner, api, _, relays, now := pairingAPI(t)
	// A second account signs in to the box with a code.
	clock := time.Now()
	api.Accounts = &AccountStore{Path: filepath.Join(t.TempDir(), "box", "accounts.json"), OwnerHex: owner.pk, OwnerNpub: npubOf(t, owner), Now: func() time.Time { return clock }}
	api.JoinCodes = &JoinCodes{Now: func() time.Time { return clock }}
	api.Pairing.Accounts = func() []string { return api.Devices.counted() }
	other := newTestKey(t)
	if st, out := call(t, srv, &other, "POST", "/api/box/accounts/join", jsonBody(map[string]string{"code": makeCode(t, srv, owner)})); st != 200 {
		t.Fatalf("join: %d %v", st, out)
	}

	// The owner shows a code. The other account sees "busy" and nothing of
	// the run: not the code, not the secret, not the device.
	_, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	if ps.State != "waiting" || ps.Code == "" {
		t.Fatalf("start: %+v", ps)
	}
	<-relays.listening
	code, _ := ParsePairCode(ps.Code, "")
	st, got := pairStatus(t, srv, other, "GET", "/api/box/pair", nil)
	if st != 200 || got.State != "busy" || got.Code != "" || got.Device != nil || got.StartedAt != 0 {
		t.Fatalf("other's view of the owner's run: %d %+v", st, got)
	}
	// It may not start over it, confirm it or cancel it.
	if st, _ := pairStatus(t, srv, other, "POST", "/api/box/pair", nil); st != 409 {
		t.Fatalf("other start over a live run: %d", st)
	}
	relays.in <- helloEvent(t, newTestKey(t), code.Secret, "Logen's iPhone", "phone", npubOf(t, owner), now.Load())
	waitState(t, srv, owner, "hello")
	if st, _ := pairStatus(t, srv, other, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`)); st != 403 {
		t.Fatalf("other confirm: %d", st)
	}
	if st, _ := pairStatus(t, srv, other, "POST", "/api/box/pair/cancel", nil); st != 403 {
		t.Fatalf("other cancel: %d", st)
	}
	if n, _ := api.Pairing.Paired.Npubs(); len(n) != 0 {
		t.Fatal("the other account got a device stored")
	}
	if ps := api.Pairing.Status(owner.pk); ps.State != "hello" { // not over HTTP: a GET in the same second is a replay
		t.Fatalf("the owner's run was touched: %+v", ps)
	}
	// The owner cancels; now the other account may pair its own device.
	if st, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair/cancel", nil); st != 200 || ps.State != "idle" {
		t.Fatalf("owner cancel: %d %+v", st, ps)
	}
	st, ps = pairStatus(t, srv, other, "POST", "/api/box/pair", []byte(`{"again":1}`))
	if st != 200 || ps.State != "waiting" {
		t.Fatalf("other start after cancel: %d %+v", st, ps)
	}
	if c, _ := ParsePairCode(ps.Code, ""); c.Owner != npubOf(t, other) {
		t.Fatalf("the code names %s, want the other account", c.Owner)
	}
	// And the owner, in turn, sees busy.
	if ps := api.Pairing.Status(owner.pk); ps.State != "busy" {
		t.Fatalf("owner during the other's run: %+v", ps)
	}
	// An expired run of another account no longer blocks.
	now.Add(pairCodeLifetime + 1)
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair", []byte(`{"again":3}`)); st != 200 {
		t.Fatalf("owner start after the other's run expired: %d", st)
	}
}

func TestSeedKeepsTheOldFileOnlyWhileAListIsUnknown(t *testing.T) {
	owner, second, boxKey, phone, old := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone, nOld := npubOf(t, boxKey), npubOf(t, phone), npubOf(t, old)
	dir := t.TempDir()
	file := filepath.Join(dir, "mesh-devices.json")
	paired := &PairedSet{Path: filepath.Join(dir, "box", "paired-devices.json")}
	src := perKeyLists{owner.pk: serverList(t, owner, nostr.Now(), nBox, nPhone)}
	counted := []string{owner.pk, second.pk}
	d := &Devices{OwnerHex: owner.pk, Accounts: func() []string { return counted }, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file, Paired: paired}
	if _, err := writeMeshDevices(file, []string{nOld}); err != nil {
		t.Fatal(err)
	}
	// The second account's list cannot be read: the old file may still be
	// naming its devices, so they stay in the seed.
	d.Refresh(context.Background())
	got, _ := paired.Npubs()
	slices.Sort(got)
	want := []string{nPhone, nOld}
	slices.Sort(want)
	if !paired.Seeded() || !slices.Equal(got, want) {
		t.Fatalf("seed with a list unknown = %v, want %v", got, want)
	}
}

func TestBoxPairingRoleClashIsToldAtTheHello(t *testing.T) {
	srv, owner, api, _, relays, now := pairingAPI(t)
	phone := newTestKey(t)
	// The same device is already paired as a Mac.
	if err := api.Pairing.Paired.Add(PairedDevice{Npub: npubOf(t, phone), Role: "mac", PairedAt: 1}); err != nil {
		t.Fatal(err)
	}
	_, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	code, _ := ParsePairCode(ps.Code, "")
	<-relays.listening
	out := api.Pairing.Hello(context.Background(), api.Pairing.run, helloEvent(t, phone, code.Secret, "Logen's iPhone", "phone", npubOf(t, owner), now.Load()))
	if out != "refuse:refuseOtherRole" {
		t.Fatalf("hello from a device paired under another role: %s", out)
	}
	_, ps = pairStatus(t, srv, owner, "GET", "/api/box/pair", nil)
	if ps.State != "waiting" || ps.Refusal != "refuseOtherRole" || ps.Device != nil {
		t.Fatalf("%+v: the code stays live and the clash is shown", ps)
	}
	// The same device as a Mac again is fine (alreadyLinked is not a clash).
	out = api.Pairing.Hello(context.Background(), api.Pairing.run, helloEvent(t, phone, code.Secret, "Logen's Mac", "mac", npubOf(t, owner), now.Load()))
	if out != "camera" {
		t.Fatalf("same role: %s", out)
	}
}

func TestBoxPairingAckNoRelayTookIsAFailure(t *testing.T) {
	srv, owner, api, _, relays, now := pairingAPI(t)
	relays.took = -1 // every relay refuses
	phone := newTestKey(t)
	_, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	code, _ := ParsePairCode(ps.Code, "")
	<-relays.listening
	relays.in <- helloEvent(t, phone, code.Secret, "Logen's iPhone", "phone", npubOf(t, owner), now.Load())
	waitState(t, srv, owner, "hello")
	st, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`))
	if st != 503 || ps.State != "linked" || ps.Acked != 0 || ps.Error == "" {
		t.Fatalf("confirm with no relay taking the ack: %d %+v", st, ps)
	}
	if n, _ := api.Pairing.Paired.Npubs(); len(n) != 1 {
		t.Fatal("the device is stored, so Remove is the way out")
	}
}
