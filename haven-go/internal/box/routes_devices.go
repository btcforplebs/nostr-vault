package box

import "net/http"

func init() {
	handle("GET /api/box/devices", FirstAccount, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, _ []byte) {
		writeJSON(w, http.StatusOK, a.Devices.Report(r.Context()))
	})
}
