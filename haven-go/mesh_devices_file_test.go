//go:build !cshared && !(js && wasm)

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The box's engine reads its paired set from HAVEN_MESH_DEVICES_FILE, in
// SetMeshDevicesC's JSON (internal/box/devices_engine.go writes it).
func TestMeshDevicesFile(t *testing.T) {
	vault, phone, mac := newTestKey(t), newTestKey(t), newTestKey(t)
	prev := meshDevices
	meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
	t.Cleanup(func() { meshDevices = prev })

	path := filepath.Join(t.TempDir(), "engine-mesh-devices.json")
	f := &meshDevicesFile{path: path}

	// No file yet: nothing paired, no self.
	f.load()
	if meshDevices.selfKey() != "" || meshDevices.paired(phone.pk) {
		t.Fatal("missing file paired something")
	}

	if err := os.WriteFile(path, []byte(meshSetJSON(t, vault, phone, mac)), 0o600); err != nil {
		t.Fatal(err)
	}
	f.load()
	if meshDevices.selfKey() != vault.pk || !meshDevices.paired(phone.pk) || !meshDevices.paired(mac.pk) {
		t.Fatal("file's set not applied")
	}

	// The Mac is removed: it is unpaired.
	os.WriteFile(path, []byte(meshSetJSON(t, vault, phone)), 0o600)
	f.load()
	if !meshDevices.paired(phone.pk) || meshDevices.paired(mac.pk) {
		t.Fatal("removal not applied")
	}

	// A broken file keeps the last good set.
	os.WriteFile(path, []byte("{not json"), 0o600)
	f.load()
	if !meshDevices.paired(phone.pk) {
		t.Fatal("broken file dropped the set")
	}

	// The file goes away: fail closed, nothing paired.
	os.Remove(path)
	f.load()
	if meshDevices.paired(phone.pk) || meshDevices.selfKey() != "" {
		t.Fatal("missing file kept devices")
	}
}
