package box

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// MeshID is the box's one identity: the mesh key nv-mesh makes on first boot
// (linux/mesh/README.md). havend has no key of its own. It reads the npub
// nv-mesh writes to mesh/npub, so the npub the owner approves in My Devices
// is the one the mesh runs as. The key itself stays nv-mesh's: havend runs
// as another uid and never reads mesh/key/.
type MeshID struct {
	NpubFile string // $NV_DATA_DIR/mesh/npub
}

// Read returns the box's mesh npub and its hex pubkey. ok is false until
// nv-mesh has made the key (first boot), or if the file holds no valid npub.
func (m MeshID) Read() (npub, pubkey string, ok bool) {
	if m.NpubFile == "" {
		return "", "", false
	}
	b, err := os.ReadFile(m.NpubFile)
	if err != nil || len(b) > 1024 {
		return "", "", false
	}
	npub = strings.TrimSpace(string(b))
	prefix, v, err := nip19.Decode(npub)
	if err != nil || prefix != "npub" || npub != strings.ToLower(npub) {
		return "", "", false
	}
	return npub, v.(string), true
}

// meshDevice is one entry of mesh-devices.json, in the shape nv-mesh reads.
type meshDevice struct {
	Npub string `json:"npub"`
}

// MeshDevices is what nv-mesh may let in as the owner's own devices: every
// fipsmesh entry of the owner's newest server list except the box itself,
// and only while that list names the box. A box the owner has not approved,
// or has removed, serves no device (nv-mesh then runs no engine).
func MeshDevices(r DevicesReport) []string {
	out := []string{}
	if !r.Box.Approved {
		return out
	}
	for _, d := range r.Devices {
		if !d.This {
			out = append(out, d.Npub)
		}
	}
	return out
}

// writeMeshDevices writes the list to path for nv-mesh, atomically and
// readable by it (another uid), and only when it changed: nv-mesh restarts
// its engine on every change.
func writeMeshDevices(path string, npubs []string) (changed bool, err error) {
	list := make([]meshDevice, 0, len(npubs))
	for _, n := range npubs {
		list = append(list, meshDevice{Npub: n})
	}
	body, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return false, err
	}
	body = append(body, '\n')
	if old, err := os.ReadFile(path); err == nil && bytes.Equal(old, body) {
		return false, nil
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".mesh-devices.*")
	if err != nil {
		return false, fmt.Errorf("writing %s: %w", path, err)
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return false, err
	}
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return false, fmt.Errorf("writing %s: %w", path, err)
	}
	return true, nil
}
