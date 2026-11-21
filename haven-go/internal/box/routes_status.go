package box

import (
	"net/http"
	"time"
)

func init() {
	handle("GET /api/box/status", func(a *API, w http.ResponseWriter, _ *http.Request, _ []byte) {
		writeJSON(w, http.StatusOK, a.status())
	})
}

func (a *API) status() Status {
	eng := a.Engine.State()
	disk, _ := DiskOf(eng.VaultDir)
	npub, _, _ := a.Mesh.Read()
	return Status{
		Version:   a.Version,
		Uptime:    int64(time.Since(a.Started).Seconds()),
		Mem:       readMem(eng.Pid),
		Disk:      disk,
		Mesh:      readMesh(a.MeshStatus, npub, time.Now()),
		Engine:    eng,
		Owner:     a.Owner,
		Device:    npub,
		Move:      a.Mover.State(),
		RelayURL:  a.RelayURL,
		UpdateVia: a.Updater.Store,
		MoveOff:   a.Mover.Off(),
	}
}
