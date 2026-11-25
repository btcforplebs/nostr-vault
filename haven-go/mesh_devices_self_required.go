package main

import "sync/atomic"

// meshSelfRequired: this engine is told its paired set from outside and
// must know its own mesh key before it trusts any copy token. The box's
// command-line engine sets it when it follows HAVEN_MESH_DEVICES_FILE
// (mesh_devices_file.go). Until havend can read nv-mesh's npub that file
// has no "self", and an empty self used to mean "no set handed over yet",
// which let every unexpired copy token through to the whole copy (Tron,
// P12 finding 1). With this set, an empty self refuses every token instead.
//
// Unset (the Mac, iPhone and Android apps before SetMeshDevicesC, and a
// command-line engine with no devices file) keeps the old rule.
var meshSelfRequired atomic.Bool

// copyTokenDeviceOK: a copy token issued to device (hex) may be used now.
// Once the paired set has a self, only a paired device's token is good.
// With no self, every token is refused when the engine needs one
// (meshSelfRequired), and allowed as before otherwise.
func (m *meshDeviceSet) copyTokenDeviceOK(device string) bool {
	if m.selfKey() == "" {
		return !meshSelfRequired.Load()
	}
	return m.paired(device)
}
