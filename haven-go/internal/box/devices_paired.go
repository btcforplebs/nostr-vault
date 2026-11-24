package box

// The switch from the owner's 10063s to the box's own paired set (Desktop
// Vaults plan §2.3, Tron N3, N5, N6). Once the paired set is seeded
// (devices_seed.go), it alone decides which devices nv-mesh and the engine
// let in: the devices report lists it, with names and roles, and
// mesh-devices.json is written from it. The 10063s are still read and shown
// (VouchedBy, Lists), but a change there adds or drops nobody. Until the
// seed, today's rule holds, so a box in the field loses no device.

// applyPaired rewrites r's devices from the paired set when it is seeded.
// false when the 10063 rule still applies.
func (d *Devices) applyPaired(r *DevicesReport) bool {
	if d.Paired == nil || !d.Paired.Seeded() {
		return false
	}
	list, err := d.Paired.List()
	if err != nil {
		return false // an unreadable set: leave the report as it was
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
	return true
}

// RemoveDevice is Remove in the box UI (Tron N6): the device leaves the
// paired set, and the next read writes mesh-devices.json without it, which
// the engine follows within seconds and revokes its copy tokens
// (haven-go mesh_devices_file.go, copyv2_server.go onMeshDeviceUnpaired).
// false when the device was not paired.
func (d *Devices) RemoveDevice(npub string) (bool, error) {
	if d.Paired == nil {
		return false, nil
	}
	return d.Paired.Remove(npub)
}
