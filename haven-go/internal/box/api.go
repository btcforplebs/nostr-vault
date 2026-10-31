package box

import (
	"encoding/json"
	"errors"
	"log"
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

	route := r.Method + " " + r.URL.Path
	switch route {
	case "GET /api/box/status":
		writeJSON(w, http.StatusOK, a.status())
	case "GET /api/box/storage":
		writeJSON(w, http.StatusOK, a.Storage.Measure(a.Mover.Engine.VaultDir()))
	case "GET /api/box/devices":
		writeJSON(w, http.StatusOK, a.Devices.Report(r.Context()))
	case "POST /api/box/update":
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
		writeJSON(w, http.StatusAccepted, res)
	case "POST /api/box/move":
		var req struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": `body must be {"path": "/mnt/..."}`})
			return
		}
		st, err := a.Mover.Begin(req.Path)
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
	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such box API route"})
	}
}

func (a *API) status() Status {
	eng := a.Engine.State()
	disk, _ := DiskOf(eng.VaultDir)
	npub, _, _ := a.Mesh.Read()
	return Status{
		Version: a.Version,
		Uptime:  int64(time.Since(a.Started).Seconds()),
		Mem:     readMem(eng.Pid),
		Disk:    disk,
		Mesh:    readMesh(a.MeshStatus, npub, time.Now()),
		Engine:  eng,
		Owner:   a.Owner,
		Device:  npub,
		Move:    a.Mover.State(),
	}
}

// MoveStarted is POST move's answer: the screens' {ok, path, message}
// (api.js) plus the move's first progress. Progress continues in status.move.
type MoveStarted struct {
	OK      bool   `json:"ok"`
	Path    string `json:"path"`
	Message string `json:"message"`
	*MoveState
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func itoa(n int) string     { return strconv.Itoa(n) }
func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
