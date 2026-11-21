package box

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"
)

// EngineDevices hands the vault engine the box's own mesh npub and its paired
// devices, the set the Mac, iPhone and Android pass in with SetMeshDevicesC
// (docs/MESH_COPY_V2_CONTRACT.md §2). The box's engine is a separate process
// with no host to call that, so havend writes the same JSON to a file and the
// engine reads it (haven-go mesh_devices_file.go, HAVEN_MESH_DEVICES_FILE).
//
// The devices are exactly the ones nv-mesh lets in: the list comes from
// mesh-devices.json (Devices.writeDevices, from the owner's 10063), so the
// mesh and the engine can never disagree on who is paired. A box the owner
// has not approved, or has removed, has an empty list there, and the engine
// then accepts no device.
type EngineDevices struct {
	Mesh MeshID // the box's mesh npub (self)
	From string // mesh-devices.json, nv-mesh's list (NV_MESH_DEVICES)
	To   string // the engine's file (HAVEN_MESH_DEVICES_FILE)
}

// engineDevicesInput is SetMeshDevicesC's JSON.
type engineDevicesInput struct {
	Self    string         `json:"self,omitempty"`
	Devices []engineDevice `json:"devices"`
}

type engineDevice struct {
	Npub string `json:"npub"`
	// Role is left out: the owner's 10063 carries no roles, and the engine
	// only asks whether a key is paired.
}

// Build is the engine's set for now. No npub yet (nv-mesh has not made its
// key): no self and no devices, which is what the engine had before it read
// this file at all. No mesh-devices.json yet: self and no devices.
func (e *EngineDevices) Build() (engineDevicesInput, error) {
	in := engineDevicesInput{Devices: []engineDevice{}}
	npub, _, ok := e.Mesh.Read()
	if !ok {
		return in, nil
	}
	in.Self = npub
	b, err := os.ReadFile(e.From)
	if errors.Is(err, fs.ErrNotExist) {
		return in, nil
	}
	if err != nil {
		return in, fmt.Errorf("reading %s: %w", e.From, err)
	}
	var list []meshDevice
	if err := json.Unmarshal(b, &list); err != nil {
		return in, fmt.Errorf("reading %s: not a device list", e.From)
	}
	for _, d := range list {
		if d.Npub == npub {
			continue // the box is never its own paired device
		}
		in.Devices = append(in.Devices, engineDevice{Npub: d.Npub})
	}
	return in, nil
}

// Sync writes the engine's file when the set changed. On an error (an
// unreadable mesh-devices.json) the engine's file is left as it was.
func (e *EngineDevices) Sync() (changed bool, err error) {
	in, err := e.Build()
	if err != nil {
		return false, err
	}
	body, err := json.Marshal(in)
	if err != nil {
		return false, err
	}
	body = append(body, '\n')
	if old, err := os.ReadFile(e.To); err == nil && bytes.Equal(old, body) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(e.To), 0o700); err != nil {
		return false, err
	}
	if err := writeFileAtomic(e.To, body, 0o600); err != nil {
		return false, err
	}
	return true, nil
}

// Run syncs now and then every interval until ctx ends. The engine re-reads
// its file on the same kind of tick, so a pairing or a removal reaches it a
// few seconds after it reaches nv-mesh.
func (e *EngineDevices) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		if changed, err := e.Sync(); err != nil {
			log.Printf("box: engine devices: %v", err)
		} else if changed {
			log.Printf("box: handed the engine its paired devices (%s)", e.To)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// writeFileAtomic writes body to path through a temp file and a rename, so
// the engine never reads half a file.
func writeFileAtomic(path string, body []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}
