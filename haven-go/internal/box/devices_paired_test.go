package box

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// Remove (Tron N6): the device leaves the paired set, the next read writes
// mesh-devices.json without it, and the engine's file follows, so the
// engine revokes its copy tokens (its own tests: mesh_devices_test.go
// TestUnpairRevokesAndEmptySetRefuses, TestUnpairWhileDownRevokesAfterRestart
// cover the refusal on the next copy, restart included).
func TestRemoveDeviceLeavesTheSetTheFileAndTheEngine(t *testing.T) {
	owner, boxKey, phone, mac := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone, nMac := npubOf(t, boxKey), npubOf(t, phone), npubOf(t, mac)
	dir := t.TempDir()
	file := filepath.Join(dir, "mesh-devices.json")
	mesh := testMeshID(t, boxKey)
	paired := &PairedSet{Path: filepath.Join(dir, "box", "paired-devices.json")}
	src := perKeyLists{owner.pk: serverList(t, owner, nostr.Now(), nBox, nPhone, nMac)}
	d := &Devices{OwnerHex: owner.pk, Mesh: mesh, Source: src, DevicesFile: file, Paired: paired}
	engine := &EngineDevices{Mesh: mesh, From: file, To: filepath.Join(dir, "box", "engine-mesh-devices.json")}
	d.Removed = func() { engine.Sync() }
	ctx := context.Background()

	// Seeded from the 10063: both devices, in the file and the engine's.
	r := d.Refresh(ctx)
	if _, err := engine.Sync(); err != nil {
		t.Fatal(err)
	}
	if !r.Paired || len(r.Devices) != 2 || !r.Box.Approved {
		t.Fatalf("after seed: %+v", r)
	}
	// Remove the phone: set, file and engine file drop it at once.
	if ok, err := d.RemoveDevice(nPhone); !ok || err != nil {
		t.Fatalf("remove: %v %v", ok, err)
	}
	r = d.Refresh(ctx)
	d.Removed()
	if got := readDevicesFile(t, file); !slices.Equal(got, []string{nMac}) {
		t.Fatalf("mesh-devices.json = %v", got)
	}
	eng, _ := engine.Paired()
	if !slices.Equal(eng, []string{nMac}) {
		t.Fatalf("engine file = %v", eng)
	}
	if len(r.Devices) != 1 || r.Devices[0].Npub != nMac {
		t.Fatalf("report = %+v", r.Devices)
	}
	// The 10063 still names the phone: it does not come back.
	r = d.Refresh(ctx)
	if len(r.Devices) != 1 || slices.Contains(readDevicesFile(t, file), nPhone) {
		t.Fatal("a removed device came back from the 10063")
	}
	// Removing the last device leaves an empty set: the box lets nobody in,
	// and says how to pair.
	if ok, _ := d.RemoveDevice(nMac); !ok {
		t.Fatal("remove mac")
	}
	r = d.Refresh(ctx)
	if r.Box.Approved || len(readDevicesFile(t, file)) != 0 || r.Hint == "" {
		t.Fatalf("after removing all: %+v file=%v", r.Box, readDevicesFile(t, file))
	}
	if ok, _ := d.RemoveDevice(nMac); ok {
		t.Fatal("removed twice")
	}
}

// The report shows the paired set's names and roles once it decides, and the
// 10063 entries stay as who vouches.
func TestDevicesReportShowsThePairedSet(t *testing.T) {
	owner, boxKey, phone := newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone := npubOf(t, boxKey), npubOf(t, phone)
	dir := t.TempDir()
	paired := &PairedSet{Path: filepath.Join(dir, "paired-devices.json")}
	src := perKeyLists{owner.pk: serverList(t, owner, nostr.Now(), nBox, nPhone)}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: filepath.Join(dir, "mesh-devices.json"), Paired: paired}
	d.Refresh(context.Background())
	if err := paired.Add(PairedDevice{Npub: nPhone, Name: "Logen's iPhone", Role: "phone", PairedAt: 42, By: npubOf(t, owner)}); err != nil {
		t.Fatal(err)
	}
	r := d.Refresh(context.Background())
	if len(r.Devices) != 1 {
		t.Fatalf("%+v", r.Devices)
	}
	e := r.Devices[0]
	if e.Name != "Logen's iPhone" || e.Role != "phone" || e.PairedAt != 42 || !e.Approved || e.Pubkey != phone.pk || len(e.VouchedBy) != 1 {
		t.Fatalf("%+v", e)
	}
	b, _ := json.Marshal(r)
	for _, want := range []string{`"paired":true`, `"pairedAt":42`} {
		if !json.Valid(b) || !containsStr(string(b), want) {
			t.Fatalf("report JSON lacks %s: %s", want, b)
		}
	}
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || indexStr(s, sub) >= 0)
}

func indexStr(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestRemoveRoute(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	phone := newTestKey(t)
	nPhone := npubOf(t, phone)
	paired := &PairedSet{Path: filepath.Join(t.TempDir(), "paired-devices.json")}
	api.Devices.Paired = paired
	api.Devices.DevicesFile = filepath.Join(t.TempDir(), "mesh-devices.json")
	// Before the seed the 10063s decide: Remove says so.
	// (Repeated calls carry a nonce: a NIP-98 proof is one-use and the same
	// request in the same second is the same event.)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/devices/remove", jsonBody(map[string]string{"npub": nPhone, "n": "1"})); st != 409 {
		t.Fatalf("remove before the seed: %d", st)
	}
	if _, err := paired.Seed([]string{nPhone}, 1); err != nil {
		t.Fatal(err)
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/devices/remove", jsonBody(map[string]string{"npub": npubOf(t, newTestKey(t))})); st != 404 {
		t.Fatalf("remove unknown: %d", st)
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/devices/remove", jsonBody(map[string]string{})); st != 400 {
		t.Fatalf("remove nothing: %d", st)
	}
	// The screen's report is cached: Remove must refresh it, or the device
	// shows for another minute (Tron #2505).
	if _, out := call(t, srv, &owner, "GET", "/api/box/devices", nil); out["paired"] != true || len(out["devices"].([]any)) != 1 {
		t.Fatalf("report before remove: %v", out)
	}
	calls := 0
	api.Devices.Removed = func() { calls++ }
	st, out := call(t, srv, &owner, "POST", "/api/box/devices/remove", jsonBody(map[string]string{"npub": nPhone}))
	if st != 200 || out["removed"] != nPhone || calls != 1 {
		t.Fatalf("remove: %d %v (engine told %d times)", st, out, calls)
	}
	// (The same GET in the same second is the same NIP-98 proof: read the
	// cached report in-process.)
	if c := api.Devices.Report(context.Background()); !c.Paired || len(c.Devices) != 0 {
		t.Fatalf("report after remove still lists the device: %+v", c)
	}
	// An unreadable set is an error, not "the 10063s decide".
	os.WriteFile(paired.Path, []byte("{trunc"), 0o600)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/devices/remove", jsonBody(map[string]string{"npub": nPhone, "n": "2"})); st != 500 {
		t.Fatalf("remove with a broken set: %d", st)
	}
	if n, _ := paired.Npubs(); len(n) != 0 {
		t.Fatal("still paired")
	}
	if b, _ := os.ReadFile(api.Devices.DevicesFile); string(b) != "[]\n" {
		t.Fatalf("mesh-devices.json = %q", b)
	}
	// Any signed-in account may not: the first account alone removes.
	if st, _ := call(t, srv, &phone, "POST", "/api/box/devices/remove", jsonBody(map[string]string{"npub": nPhone})); st != 403 {
		t.Fatalf("stranger remove: %d", st)
	}
}

// Tron #2505 must-fix 1: a box no 10063 names never seeds from the lists,
// so its first confirmed pairing is the seed. The set then decides, takes
// what mesh-devices.json held, and the paired phone is let in at once.
func TestFirstPairingSeedsAnUnseededBox(t *testing.T) {
	owner, boxKey, phone, old := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nPhone, nOld := npubOf(t, phone), npubOf(t, old)
	dir := t.TempDir()
	file := filepath.Join(dir, "mesh-devices.json")
	paired := &PairedSet{Path: filepath.Join(dir, "box", "paired-devices.json"), MeshFile: file}
	// The owner's 10063 does not name the box: unapproved, nothing to seed.
	src := perKeyLists{owner.pk: serverList(t, owner, nostr.Now(), nOld)}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file, Paired: paired}
	ctx := context.Background()
	if r := d.Refresh(ctx); r.Paired || r.Box.Approved || paired.Seeded() {
		t.Fatalf("an unapproved box seeded from nothing: %+v", r)
	}
	// What nv-mesh let in before (a hand-written file, say) is kept.
	if _, err := writeMeshDevices(file, []string{nOld}); err != nil {
		t.Fatal(err)
	}
	if err := paired.Add(PairedDevice{Npub: nPhone, Name: "Logen's iPhone", Role: "phone", PairedAt: 42, By: npubOf(t, owner)}); err != nil {
		t.Fatal(err)
	}
	if !paired.Seeded() {
		t.Fatal("the first pairing did not seed the set")
	}
	r, ok := d.PairedChanged()
	if !ok || !r.Paired || !r.Box.Approved || len(r.Devices) != 2 {
		t.Fatalf("after the first pairing: %v %+v", ok, r)
	}
	if got := readDevicesFile(t, file); !slices.Equal(got, []string{nOld, nPhone}) {
		t.Fatalf("mesh-devices.json = %v", got)
	}
	// Report serves it from the cache, and the next relay read keeps it:
	// the 10063 that leaves the box out adds or drops nobody now.
	if c := d.Report(ctx); len(c.Devices) != 2 || !c.Paired {
		t.Fatalf("cached report %+v", c)
	}
	if r := d.Refresh(ctx); len(r.Devices) != 2 || !slices.Equal(readDevicesFile(t, file), []string{nOld, nPhone}) {
		t.Fatalf("after a 10063 read: %+v file=%v", r.Devices, readDevicesFile(t, file))
	}
	list, _ := paired.List()
	if list[0].From != "seed" || list[0].Npub != nOld || list[1].From != "pair" || list[1].Npub != nPhone {
		t.Fatalf("set = %+v", list)
	}
}

// Tron #2505 must-fix 2: a paired set that exists but can't be read decides
// nothing, and the 10063 rule must not take over, or a device Remove dropped
// comes back from the lists. mesh-devices.json is left as it was.
func TestUnreadablePairedSetFailsClosed(t *testing.T) {
	owner, boxKey, phone, mac := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone, nMac := npubOf(t, boxKey), npubOf(t, phone), npubOf(t, mac)
	dir := t.TempDir()
	file := filepath.Join(dir, "mesh-devices.json")
	paired := &PairedSet{Path: filepath.Join(dir, "box", "paired-devices.json")}
	src := perKeyLists{owner.pk: serverList(t, owner, nostr.Now(), nBox, nPhone, nMac)}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file, Paired: paired}
	ctx := context.Background()
	d.Refresh(ctx)
	if ok, _ := d.RemoveDevice(nPhone); !ok {
		t.Fatal("remove")
	}
	if _, ok := d.PairedChanged(); !ok || !slices.Equal(readDevicesFile(t, file), []string{nMac}) {
		t.Fatalf("after remove: %v", readDevicesFile(t, file))
	}
	if err := os.WriteFile(paired.Path, []byte("{trunc"), 0o600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		r := d.Refresh(ctx)
		if got := readDevicesFile(t, file); !slices.Equal(got, []string{nMac}) {
			t.Fatalf("read %d: the phone came back from the 10063: %v", i, got)
		}
		if r.Paired || r.Hint == "" {
			t.Fatalf("read %d: the report hides the broken set: %+v", i, r)
		}
	}
	if seeded, err := paired.State(); seeded || err == nil {
		t.Fatalf("State = %v %v", seeded, err)
	}
	// Remove and PairedChanged write nothing either.
	if _, ok := d.PairedChanged(); ok || !slices.Equal(readDevicesFile(t, file), []string{nMac}) {
		t.Fatalf("PairedChanged on a broken set: %v %v", ok, readDevicesFile(t, file))
	}
	// A missing file is the 10063 rule again (nothing to fail closed on).
	os.Remove(paired.Path)
	if r := d.Refresh(ctx); !r.Paired || len(r.Devices) != 2 {
		t.Fatalf("after the file is gone, the lists seed again: %+v", r)
	}
}
