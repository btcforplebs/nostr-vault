package box

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/nbd-wtf/go-nostr/nip19"
)

func engineDevicesFixture(t *testing.T) (*EngineDevices, string, string) {
	t.Helper()
	dir := t.TempDir()
	box := newTestKey(t)
	boxNpub, _ := nip19.EncodePublicKey(box.pk)
	npubFile := filepath.Join(dir, "mesh", "npub")
	if err := os.MkdirAll(filepath.Dir(npubFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(npubFile, []byte(boxNpub+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &EngineDevices{
		Mesh: MeshID{NpubFile: npubFile},
		From: filepath.Join(dir, "mesh-devices.json"),
		To:   filepath.Join(dir, "box", "engine-mesh-devices.json"),
	}, boxNpub, npubFile
}

func readEngineDevices(t *testing.T, path string) engineDevicesInput {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var in engineDevicesInput
	if err := json.Unmarshal(b, &in); err != nil {
		t.Fatal(err)
	}
	return in
}

// The engine gets the box's npub as self and exactly nv-mesh's devices.
func TestEngineDevicesFollowsMeshDevices(t *testing.T) {
	e, boxNpub, _ := engineDevicesFixture(t)
	phone, mac := newTestKey(t), newTestKey(t)
	phoneNpub, _ := nip19.EncodePublicKey(phone.pk)
	macNpub, _ := nip19.EncodePublicKey(mac.pk)
	if _, err := writeMeshDevices(e.From, []string{phoneNpub, macNpub}); err != nil {
		t.Fatal(err)
	}
	changed, err := e.Sync()
	if err != nil || !changed {
		t.Fatalf("first sync: changed %v err %v", changed, err)
	}
	in := readEngineDevices(t, e.To)
	if in.Self != boxNpub || len(in.Devices) != 2 || in.Devices[0].Npub != phoneNpub || in.Devices[1].Npub != macNpub {
		t.Fatalf("engine set = %+v", in)
	}
	if fi, _ := os.Stat(e.To); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
	if changed, _ := e.Sync(); changed {
		t.Fatal("unchanged set rewritten")
	}

	// The owner removes the Mac: it leaves the engine's set too.
	if _, err := writeMeshDevices(e.From, []string{phoneNpub}); err != nil {
		t.Fatal(err)
	}
	if changed, err := e.Sync(); err != nil || !changed {
		t.Fatalf("removal: changed %v err %v", changed, err)
	}
	if in := readEngineDevices(t, e.To); len(in.Devices) != 1 || in.Devices[0].Npub != phoneNpub {
		t.Fatalf("after removal = %+v", in)
	}

	// The owner un-approves the box: nv-mesh's list is empty, so is the engine's.
	if _, err := writeMeshDevices(e.From, nil); err != nil {
		t.Fatal(err)
	}
	e.Sync()
	if in := readEngineDevices(t, e.To); in.Self != boxNpub || len(in.Devices) != 0 {
		t.Fatalf("after un-approve = %+v", in)
	}
}

// Before nv-mesh made its key the engine gets no self and no devices (what
// it had before this file existed); before the first list, self and none.
func TestEngineDevicesBeforeTheMeshIsUp(t *testing.T) {
	e, boxNpub, npubFile := engineDevicesFixture(t)
	os.Remove(npubFile)
	if _, err := e.Sync(); err != nil {
		t.Fatal(err)
	}
	if in := readEngineDevices(t, e.To); in.Self != "" || len(in.Devices) != 0 {
		t.Fatalf("no npub = %+v", in)
	}
	os.WriteFile(npubFile, []byte(boxNpub), 0o600)
	if _, err := e.Sync(); err != nil {
		t.Fatal(err)
	}
	if in := readEngineDevices(t, e.To); in.Self != boxNpub || len(in.Devices) != 0 {
		t.Fatalf("no list = %+v", in)
	}
}

// An unreadable nv-mesh list leaves the engine's set as it was, and the box
// itself is never listed as its own device.
func TestEngineDevicesBadListKeepsLastAndSkipsSelf(t *testing.T) {
	e, boxNpub, _ := engineDevicesFixture(t)
	phone := newTestKey(t)
	phoneNpub, _ := nip19.EncodePublicKey(phone.pk)
	if _, err := writeMeshDevices(e.From, []string{boxNpub, phoneNpub}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Sync(); err != nil {
		t.Fatal(err)
	}
	if in := readEngineDevices(t, e.To); len(in.Devices) != 1 || in.Devices[0].Npub != phoneNpub {
		t.Fatalf("self listed: %+v", in)
	}
	os.WriteFile(e.From, []byte("not json"), 0o644)
	if _, err := e.Sync(); err == nil {
		t.Fatal("bad list accepted")
	}
	if in := readEngineDevices(t, e.To); len(in.Devices) != 1 {
		t.Fatalf("bad list changed the engine's set: %+v", in)
	}
}
