package box

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
)

// API is the owner-only box API under /api/box/. Every route needs a NIP-98
// proof signed by NV_OWNER; nobody else gets anything, not even the version.
type API struct {
	Auth    *OwnerAuth
	Version string
	Started time.Time
	Mesh    MeshID // the box's one npub, the mesh's
	Owner   string // npub
	// RelayURL is NV_RELAY_URL, the box's own web address if it has one
	// (Config.RelayURL); the box screen's Public on the web part shows it.
	RelayURL string

	Engine     interface{ State() EngineState }
	MeshStatus string // path of the mesh status file
	Storage    *StorageMeter
	Devices    *Devices
	Mover      *Mover
	Updater    *Updater
}

func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	body, err := a.Auth.Check(r)
	if err != nil {
		var ae *AuthError
		status := http.StatusUnauthorized
		if errors.As(err, &ae) {
			status = ae.Status
		}
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Nostr`)
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	route, ok := boxRoutes[r.Method+" "+r.URL.Path]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such box API route"})
		return
	}
	route(a, w, r, body)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func itoa(n int) string     { return strconv.Itoa(n) }
func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
