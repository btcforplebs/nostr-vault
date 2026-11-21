package box

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
)

func init() {
	handle("POST /api/box/move", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		var req struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": `body must be {"path": "/mnt/..."}`})
			return
		}
		st, err := a.Mover.Begin(req.Path)
		if errors.Is(err, ErrMoveOff) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": err.Error()})
			return
		}
		if errors.Is(err, ErrMoveBusy) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
			return
		}
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		log.Printf("box: moving the vault from %s to %s", st.From, st.To)
		writeJSON(w, http.StatusAccepted, MoveStarted{
			OK: true, Path: st.To, MoveState: st,
			Message: "Moving your vault to " + st.To + ". The box stops serving while it copies, then starts again.",
		})
	})
}

// MoveStarted is POST move's answer: the screens' {ok, path, message}
// (api.js) plus the move's first progress. Progress continues in status.move.
type MoveStarted struct {
	OK      bool   `json:"ok"`
	Path    string `json:"path"`
	Message string `json:"message"`
	*MoveState
}
