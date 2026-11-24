package box

import (
	"log"
	"time"
)

// The switch from the owner's 10063s to the box's own paired set (Desktop
// Vaults plan §2.3, Tron N3, N5, N6). Once the paired set is seeded
// (devices_seed.go), it alone decides which devices nv-mesh and the engine
// let in: the devices report lists it, with names and roles, and
// mesh-devices.json is written from it. The 10063s are still read and shown
// (VouchedBy, Lists), but a change there adds or drops nobody. Until the
// seed, today's rule holds, so a box in the field loses no device.

// applyPaired rewrites r's devices from the paired set when it is seeded.
// false when the 10063 rule still applies. An error when the set's file
// exists but can't be read: then neither rule applies and the caller leaves
// mesh-devices.json as it is (Tron #2505: a device Remove dropped must not
// come back from the lists because the file broke). The report says so.
func (d *Devices) applyPaired(r *DevicesReport) (bool, error) {
	if d.Paired == nil {
		return false, nil
	}
	seeded, err := d.Paired.State()
	if err == nil && !seeded {
		return false, nil
	}
	var list []PairedDevice
	if err == nil {
		list, err = d.Paired.List()
	}
	if err != nil {
		r.Hint = "The box can't read its paired-devices file, so no device is added or removed until it is fixed: " + err.Error()
		return false, err
	}
	vouched := map[string][]string{}
	for _, e := range r.Devices {
		vouched[e.Npub] = e.VouchedBy
	}
	_, boxPubkey, _ := d.Mesh.Read()
	r.Paired = true
	r.Devices = r.Devices[:0]
	for _, p := range list {
		pk, _, err := ParseOwner(p.Npub)
		if err != nil || pk == boxPubkey {
			continue // the box is never its own paired device
		}
		e := MeshEntry{Npub: p.Npub, Pubkey: pk, Name: p.Name, Role: p.Role, Approved: true, PairedAt: p.PairedAt, VouchedBy: vouched[p.Npub]}
		r.Devices = append(r.Devices, e)
	}
	// With its own set, the box is "approved" by having a device paired.
	r.Box.Approved = len(r.Devices) > 0
	switch {
	case r.Box.Npub == "":
	case len(r.Devices) == 0:
		r.Hint = "No devices paired. In this box's My Devices, tap Add a device and scan the code with your phone."
	default:
		r.Hint = ""
	}
	return true, nil
}

// PairedChanged rewrites the report and mesh-devices.json from the paired
// set now, with no relay read: Remove and a confirmed pairing change the
// set, not the 10063s, so they need not wait on a fetch from every counted
// account (Tron #2505). The report fills Report's cache, so the devices
// screen shows the change at once rather than after the cache's minute.
// false when the set does not decide (not seeded, or unreadable): nothing
// is written then, and the cache is dropped so the next Report reads afresh.
func (d *Devices) PairedChanged() (DevicesReport, bool) {
	d.wmu.Lock()
	npub, pubkey, _ := d.Mesh.Read()
	r := buildAccountsReport(npub, pubkey, d.counted(), d.lists)
	paired, err := d.applyPaired(&r)
	if err != nil {
		log.Printf("box: paired set: %v; mesh-devices.json left as it was", err)
	}
	if paired && d.DevicesFile != "" {
		devices := MeshDevices(r)
		if changed, err := writeMeshDevices(d.DevicesFile, devices); err != nil {
			log.Printf("box: %v", err)
		} else if changed {
			log.Printf("box: mesh devices now %d (the box's paired set)", len(devices))
		}
	}
	d.wmu.Unlock()
	d.mu.Lock()
	if paired {
		d.cached, d.at = &r, time.Now()
	} else {
		d.cached = nil
	}
	d.mu.Unlock()
	return r, paired
}

// RemoveDevice is Remove in the box UI (Tron N6): the device leaves the
// paired set; PairedChanged then writes mesh-devices.json without it, which
// the engine follows and revokes its copy tokens (haven-go
// mesh_devices_file.go, copyv2_server.go onMeshDeviceUnpaired). false when
// the device was not paired.
func (d *Devices) RemoveDevice(npub string) (bool, error) {
	if d.Paired == nil {
		return false, nil
	}
	return d.Paired.Remove(npub)
}

// pairedState is the paired set's State; "not seeded" with no set.
func (d *Devices) pairedState() (bool, error) {
	if d.Paired == nil {
		return false, nil
	}
	return d.Paired.State()
}
