package box

import (
	"encoding/json"
	"errors"
	"net/http"
)

// Two-scan pairing from the box web UI (pairing_box.go). Any signed-in
// account may pair its own devices, as any signed-in account's 10063
// vouches for devices today (devices_accounts.go); the hello's owner must
// be the caller's account, or the session says switchTo. A run belongs to
// the account that started it: another account sees only "busy", and may
// neither confirm nor cancel it (Tron #2502).
func init() {
	handle("GET /api/box/pair", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		writeJSON(w, http.StatusOK, a.Pairing.Status(c.Pubkey))
	})
	handle("POST /api/box/pair", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, c Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		st, err := a.Pairing.Start(r.Context(), c.Pubkey)
		if errors.Is(err, ErrNotYours) {
			writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "pairing": st})
			return
		}
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
	handle("POST /api/box/pair/confirm", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, c Caller, body []byte) {
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
		st, err := a.Pairing.Confirm(r.Context(), c.Pubkey, in.Role)
		switch {
		case errors.Is(err, ErrNotYours):
			writeJSON(w, http.StatusForbidden, map[string]any{"error": err.Error(), "pairing": st})
			return
		case errors.Is(err, ErrNotReady), errors.Is(err, ErrRoleMismatch), errors.Is(err, ErrPairedOtherRole):
			writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "pairing": st})
			return
		case errors.Is(err, ErrNoAck):
			// Stored, but the phone will not hear back: the UI shows it as a
			// failure with the way out.
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error(), "pairing": st})
			return
		case err != nil:
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": pairErr(err), "pairing": st})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
	handle("POST /api/box/pair/cancel", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		if a.Pairing == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not pair devices itself yet"})
			return
		}
		st, err := a.Pairing.Cancel(c.Pubkey)
		if err != nil {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": err.Error(), "pairing": st})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
}
