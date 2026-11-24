package box

import (
	"encoding/json"
	"errors"
	"net/http"
)

// Two-scan pairing from the box web UI (pairing_box.go). Any signed-in
// account may pair its own devices, as any signed-in account's 10063
// vouches for devices today (devices_accounts.go); the hello's owner must
// be the caller's account, or the session says switchTo.
func init() {
	handle("GET /api/box/pair", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		writeJSON(w, http.StatusOK, a.Pairing.Status())
	})
	handle("POST /api/box/pair", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, c Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		st, err := a.Pairing.Start(r.Context(), c.Pubkey)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
	handle("POST /api/box/pair/confirm", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, body []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		var in struct {
			Role string `json:"role"`
		}
		if err := json.Unmarshal(body, &in); err != nil || !isPairRole(in.Role) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "confirm needs the role shown: {\"role\":\"phone\"}"})
			return
		}
		st, err := a.Pairing.Confirm(r.Context(), in.Role)
		switch {
		case errors.Is(err, ErrNotReady), errors.Is(err, ErrRoleMismatch), errors.Is(err, ErrPairedOtherRole):
			writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "pairing": st})
			return
		case err != nil:
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": pairErr(err), "pairing": st})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
	handle("POST /api/box/pair/cancel", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		writeJSON(w, http.StatusOK, a.Pairing.Cancel())
	})
}
