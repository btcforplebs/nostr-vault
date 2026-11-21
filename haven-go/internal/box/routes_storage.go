package box

import "net/http"

func init() {
	handle("GET /api/box/storage", func(a *API, w http.ResponseWriter, _ *http.Request, _ []byte) {
		st := a.Storage.Measure(a.Mover.Engine.VaultDir())
		st.MoveOff = a.Mover.Off()
		writeJSON(w, http.StatusOK, st)
	})
}
