package box

// Backup now and restore on a box (One Vault spec E5; the work is backup.go).
// First account only: a backup holds every account's notes, and a restore
// stops the vault for everyone.
//
//	GET  /api/box/backups          {backups: [{name, size, createdAt}], job}  newest first; job: the current or last
//	                               backup, restore or restart (EngineJob), absent before the first
//	POST /api/box/backups/now      -> 202 the job
//	POST /api/box/backups/restore  {"name":"vault-20261122-010203.zip"} -> 202 the job

import (
	"encoding/json"
	"net/http"
	"time"
)

func init() {
	handle("GET /api/box/backups", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		writeJSON(w, http.StatusOK, map[string]any{"backups": a.Mover.Backups(), "job": lastEngineJob()})
	})
	handle("POST /api/box/backups/now", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		job, err := a.Mover.BackupNow(time.Now())
		answerEngineJob(w, job, err)
	})
	handle("POST /api/box/backups/restore", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		var req struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(body, &req) != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "send {\"name\": a backup's name}"})
			return
		}
		job, err := a.Mover.Restore(req.Name)
		answerEngineJob(w, job, err)
	})
}

// answerEngineJob: 202 and the job it started, 409 while the vault is busy,
// 400 for anything else wrong with the request.
func answerEngineJob(w http.ResponseWriter, job *EngineJob, err error) {
	switch {
	case err == ErrEngineBusy:
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
	case err != nil:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
	default:
		writeJSON(w, http.StatusAccepted, job)
	}
}
