package box

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

// The box catching up from the owner's other vaults (sync.go). Any signed-in
// account: the box starts copies with its own device key, so who asks
// changes nothing, and the state is per device.
func init() {
	handle("GET /api/box/sync", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, _ []byte) {
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		rep, err := a.Sync.Report(r.Context())
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, rep)
	})
	handle("POST /api/box/sync/now", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		device, ok := syncDeviceArg(w, body, false)
		if !ok {
			return
		}
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		if err := a.Sync.Now(device); err != nil {
			syncError(w, err)
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "device": device})
	})
	handle("POST /api/box/sync/first", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, body []byte) {
		device, ok := syncDeviceArg(w, body, true)
		if !ok {
			return
		}
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		if err := a.Sync.First(r.Context(), device); err != nil {
			syncError(w, err)
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "device": device})
	})
}

// syncDeviceArg reads {"device":"npub1…"}; an empty body is "all" unless
// required.
func syncDeviceArg(w http.ResponseWriter, body []byte, required bool) (string, bool) {
	var in struct {
		Device string `json:"device"`
	}
	if len(strings.TrimSpace(string(body))) > 0 {
		if err := json.Unmarshal(body, &in); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body is not JSON"})
			return "", false
		}
	}
	in.Device = strings.TrimSpace(in.Device)
	if in.Device == "" && !required {
		return "", true
	}
	_, npub, err := ParseOwner(in.Device)
	if err != nil || !strings.HasPrefix(in.Device, "npub1") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "device must be a device's npub"})
		return "", false
	}
	return npub, true
}

func syncError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotPaired):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
	case errors.Is(err, ErrCopyBusy):
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
	default:
		// nv-mesh could not reach it, or the engine is down.
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
	}
}
