package box

import (
	"encoding/json"
	"net/http"
)

func init() {
	handle("GET /api/box/devices", FirstAccount, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, _ []byte) {
		writeJSON(w, http.StatusOK, a.Devices.Report(r.Context()))
	})
	// Remove (Tron N6): the device leaves the box's paired set now, and the
	// set is written out at once for nv-mesh and the engine, so its copy
	// tokens are revoked within seconds (devices_paired.go). Only once the
	// paired set decides (Report().Paired); before that the owner removes a
	// device from their 10063 on the phone, as today.
	handle("POST /api/box/devices/remove", FirstAccount, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, body []byte) {
		var in struct {
			Npub string `json:"npub"`
		}
		if err := json.Unmarshal(body, &in); err != nil || in.Npub == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "remove needs {\"npub\":\"npub1…\"}"})
			return
		}
		seeded, err := a.Devices.pairedState()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		if !seeded {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "this box still follows your media server list: remove the device from My Devices on your phone"})
			return
		}
		removed, err := a.Devices.RemoveDevice(in.Npub)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		if !removed {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "that device is not paired with this box"})
			return
		}
		// From the set, with no relay read, and into the report's cache, so
		// the screen shows the device gone now (Tron #2505).
		rep, ok := a.Devices.PairedChanged()
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the device left the paired set, but the box could not rewrite its mesh device list"})
			return
		}
		if a.Devices.Removed != nil {
			a.Devices.Removed()
		}
		writeJSON(w, http.StatusOK, map[string]any{"removed": in.Npub, "devices": rep})
	})
}
