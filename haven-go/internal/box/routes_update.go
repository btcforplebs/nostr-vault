package box

import (
	"errors"
	"log"
	"net/http"
)

func init() {
	handle("POST /api/box/update", func(a *API, w http.ResponseWriter, _ *http.Request, _ []byte) {
		res, err := a.Updater.Request()
		if errors.Is(err, ErrUpdateBusy) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
			return
		}
		if err != nil {
			log.Printf("box: update request failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not queue the update"})
			return
		}
		res.From = a.Version
		log.Printf("box: update requested via %s", res.Via)
		if !res.Started {
			writeJSON(w, http.StatusOK, res)
			return
		}
		writeJSON(w, http.StatusAccepted, res)
	})
}
