package box

import (
	"encoding/json"
	"log"
	"os"
	"time"
)

// The one-time seed of the box's paired set (paired.go) from what the box
// trusts today (Desktop Vaults plan §2.3, Tron N3, N5). It runs on each
// settled read of the counted accounts' 10063s (Devices.read), and only:
//
//   - after a settled read: at least one account's list is known, the same
//     guard that keeps mesh-devices.json as it was while no list is known;
//   - from a non-empty set: the devices nv-mesh lets in now (every counted
//     account's mesh entries, while the box is approved). What
//     mesh-devices.json held before is added only while some counted
//     account's list is still unknown: with every list read, the lists are
//     the whole truth, and a device the owner dropped from their 10063
//     while the box was off must not come back from the old file (Tron
//     #2502). "Seeded" is never written from nothing.
//
// Until the seed happens, and in this PR after it too, mesh-devices.json
// follows the 10063s as before. P9b switches it to the paired set.

// seedPaired is called by Devices.read under wmu with the merged report;
// before is what mesh-devices.json held before this read wrote it, and
// allKnown whether every counted account's list is known.
func (d *Devices) seedPaired(r DevicesReport, settled, allKnown bool, before []string) {
	if d.Paired == nil || !settled || d.Paired.Seeded() {
		return
	}
	npubs := MeshDevices(r)
	if !allKnown {
		npubs = append(npubs, before...)
	}
	seeded, err := d.Paired.Seed(npubs, time.Now().Unix())
	if err != nil {
		log.Printf("box: paired set: %v", err)
	} else if seeded {
		n, _ := d.Paired.Npubs()
		log.Printf("box: paired set seeded with %d devices from the 10063s and mesh-devices.json", len(n))
	}
}

// readMeshDevicesList is the npubs mesh-devices.json names now; none when
// it is missing or unreadable.
func readMeshDevicesList(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var list []meshDevice
	if json.Unmarshal(b, &list) != nil {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, m := range list {
		if m.Npub != "" {
			out = append(out, m.Npub)
		}
	}
	return out
}
