//go:build !cshared && !(js && wasm)

package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"strings"
	"time"
)

// The command-line engine (the Linux box's haven-engine) has no host to call
// SetMeshDevicesC, so it reads the same JSON from the file
// HAVEN_MESH_DEVICES_FILE names: havend writes it from the devices nv-mesh
// lets in (internal/box/devices_engine.go). Read at start, then re-read on
// every tick when it changed. Unset: nothing is read and the set stays empty,
// as before.
//
// A missing file is an empty set: no self, no device (fail closed, like the
// apps' empty set). A file that does not parse keeps the last good set, as
// SetMeshDevicesC does with bad input.

const meshDevicesFileEvery = 5 * time.Second

// meshDevicesFile follows one file into meshDevices.
type meshDevicesFile struct {
	path string
	last []byte // the body last applied; nil before the first read
	read bool
}

// load reads the file and applies it when it changed since the last load.
func (f *meshDevicesFile) load() {
	body, err := os.ReadFile(f.path)
	if errors.Is(err, os.ErrNotExist) {
		body, err = []byte("{}"), nil
	}
	if err != nil {
		log.Printf("🚫 mesh devices file: %v", err)
		return
	}
	if f.read && bytes.Equal(body, f.last) {
		return
	}
	if err := meshDevices.set(string(body)); err != nil {
		log.Printf("🚫 mesh devices file %s: %v (keeping the last set)", f.path, err)
		f.last, f.read = body, true // log a bad file once, not every tick
		return
	}
	f.last, f.read = body, true
	log.Printf("🔑 mesh devices from %s: %d paired", f.path, meshDevices.count())
}

// startMeshDevicesFile reads HAVEN_MESH_DEVICES_FILE now and follows it until
// ctx ends.
func startMeshDevicesFile(ctx context.Context) {
	path := strings.TrimSpace(hostGetenv("HAVEN_MESH_DEVICES_FILE"))
	if path == "" {
		return
	}
	f := &meshDevicesFile{path: path}
	f.load()
	go func() {
		t := time.NewTicker(meshDevicesFileEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				f.load()
			}
		}
	}()
}

// count: how many devices are paired now.
func (m *meshDeviceSet) count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.devices)
}
