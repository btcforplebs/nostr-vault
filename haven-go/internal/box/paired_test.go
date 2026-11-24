package box

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

func TestPairedSetSeedOnceAddRemove(t *testing.T) {
	p := &PairedSet{Path: filepath.Join(t.TempDir(), "box", "paired-devices.json")}
	phone, mac, later := npubOf(t, newTestKey(t)), npubOf(t, newTestKey(t)), npubOf(t, newTestKey(t))

	// An empty seed writes nothing, and the set is not seeded.
	if ok, err := p.Seed(nil, 100); ok || err != nil {
		t.Fatalf("empty seed: %v %v", ok, err)
	}
	if p.Seeded() {
		t.Fatal("seeded from nothing")
	}
	if _, err := os.Stat(p.Path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a file was written for an empty seed")
	}
	// A real seed happens once: a second seed changes nothing.
	if ok, err := p.Seed([]string{phone, mac, phone, "not-an-npub"}, 100); !ok || err != nil {
		t.Fatalf("seed: %v %v", ok, err)
	}
	if ok, _ := p.Seed([]string{later}, 200); ok {
		t.Fatal("seeded twice")
	}
	got, _ := p.Npubs()
	if !p.Seeded() || !slices.Equal(got, []string{phone, mac}) {
		t.Fatalf("after seed: %v", got)
	}
	list, _ := p.List()
	if list[0].From != "seed" || list[0].Role != "" || list[0].PairedAt != 100 {
		t.Fatalf("seeded entry = %+v", list[0])
	}

	// Pairing a seeded device fills in its role and name; another role on a
	// paired device is refused; a new device is appended.
	if err := p.Add(PairedDevice{Npub: phone, Name: "Logen's iPhone", Role: "phone", PairedAt: 300, By: "npub1owner"}); err != nil {
		t.Fatal(err)
	}
	list, _ = p.List()
	if list[0].Role != "phone" || list[0].Name != "Logen's iPhone" || list[0].From != "pair" || list[0].PairedAt != 300 {
		t.Fatalf("paired-over seed entry = %+v", list[0])
	}
	if err := p.Add(PairedDevice{Npub: phone, Role: "homeVault", PairedAt: 400}); !errors.Is(err, ErrPairedOtherRole) {
		t.Fatalf("other role: %v", err)
	}
	if err := p.Add(PairedDevice{Npub: later, Role: "browser", PairedAt: 500}); err != nil {
		t.Fatal(err)
	}
	got, _ = p.Npubs()
	if !slices.Equal(got, []string{phone, mac, later}) {
		t.Fatalf("after add: %v", got)
	}
	// The file stays havend's alone.
	if fi, _ := os.Stat(p.Path); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", fi.Mode().Perm())
	}

	// Remove drops one; removing again or an unknown is false, not an error.
	if ok, err := p.Remove(mac); !ok || err != nil {
		t.Fatalf("remove: %v %v", ok, err)
	}
	if ok, err := p.Remove(mac); ok || err != nil {
		t.Fatalf("remove again: %v %v", ok, err)
	}
	got, _ = p.Npubs()
	if !slices.Equal(got, []string{phone, later}) || !p.Seeded() {
		t.Fatalf("after remove: %v seeded=%v", got, p.Seeded())
	}

	// A damaged file reads as not seeded, and Seed refuses to write over it.
	if err := os.WriteFile(p.Path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if p.Seeded() {
		t.Fatal("a damaged file read as seeded")
	}
	if _, err := p.Seed([]string{phone}, 600); err == nil {
		t.Fatal("seed wrote over a damaged file")
	}
}

// The seed waits for a settled 10063 read, takes the devices nv-mesh lets in
// plus mesh-devices.json, happens once, and leaves mesh-devices.json
// following the 10063s (the P9b switch is not in this PR).
func TestDevicesSeedThePairedSetOnceAfterASettledRead(t *testing.T) {
	owner, boxKey, phone, mac, old, late := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone, nMac, nOld, nLate := npubOf(t, boxKey), npubOf(t, phone), npubOf(t, mac), npubOf(t, old), npubOf(t, late)
	_ = nOld
	dir := t.TempDir()
	file := filepath.Join(dir, "mesh-devices.json")
	paired := &PairedSet{Path: filepath.Join(dir, "box", "paired-devices.json")}
	src := perKeyLists{}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file, Paired: paired}
	ctx := context.Background()

	// 1. Relays and vault silent: no list known, nothing seeded.
	d.Refresh(ctx)
	if paired.Seeded() {
		t.Fatal("seeded with no list known")
	}
	// 2. A list that does not approve the box: the box lets nobody in today,
	// so there is nothing to seed from ("no set yet" is not a revocation).
	src[owner.pk] = serverList(t, owner, nostr.Now()-20, nPhone)
	d.Refresh(ctx)
	if paired.Seeded() {
		t.Fatal("seeded while the box is not approved")
	}
	// 3. mesh-devices.json holds a device the owner dropped from their
	// 10063 while the box was off; the list now approves the box and names
	// the phone and the Mac. Every counted account's list is known, so the
	// lists are the whole truth: the seed is the phone and the Mac, once,
	// and the dropped device does not come back (Tron #2502).
	if _, err := writeMeshDevices(file, []string{nOld}); err != nil {
		t.Fatal(err)
	}
	src[owner.pk] = serverList(t, owner, nostr.Now()-10, nBox, nPhone, nMac)
	d.Refresh(ctx)
	got, _ := paired.Npubs()
	slices.Sort(got)
	want := []string{nPhone, nMac}
	slices.Sort(want)
	if !paired.Seeded() || !slices.Equal(got, want) {
		t.Fatalf("seed = %v, want %v", got, want)
	}
	// 4. A newer 10063 adds a device: the paired set now decides, so
	// mesh-devices.json does not follow it and the set does not change.
	src[owner.pk] = serverList(t, owner, nostr.Now(), nBox, nPhone, nMac, nLate)
	r := d.Refresh(ctx)
	mesh := readDevicesFile(t, file)
	slices.Sort(mesh)
	if slices.Contains(mesh, nLate) || !slices.Equal(mesh, want) || !r.Paired {
		t.Fatalf("mesh-devices.json = %v (paired=%v): the paired set decides after the seed", mesh, r.Paired)
	}
	again, _ := paired.Npubs()
	slices.Sort(again)
	if !slices.Equal(again, want) {
		t.Fatalf("paired set changed after the seed: %v", again)
	}
}
