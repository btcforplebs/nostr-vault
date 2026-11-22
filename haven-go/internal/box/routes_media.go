package box

// Auto-Mirror and Copy to servers on a box (One Vault spec E6). The engine
// runs both jobs (haven-go auto_mirror.go, media_copy_job.go); the box only
// hands it the switch and the requests through files in the vault folder,
// the engine's working directory, and reads back what it wrote.
//
//	GET  /api/box/media/auto-mirror      the switch and the last run      (signed in)
//	PUT  /api/box/media/auto-mirror      {"enabled":bool}                  (first account)
//	POST /api/box/media/auto-mirror/run  run now, skipping the 3 h wait    (signed in)
//	POST /api/box/media/copy/check       which of my files each server lacks (signed in)
//	POST /api/box/media/copy             {"auths":[...]} send them         (signed in)
//	GET  /api/box/media/copy             the last check or copy, mine only (signed in)
//
// Auto-Mirror covers every signed-in account at once, so it is one switch
// for the box and only the first account turns it on or off. Copy to servers
// is per account: each runs for the caller alone, with upload auths the
// caller signed in the browser (the box holds no account key), and the
// engine checks each auth is the caller's.

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// The engine's file names (haven-go auto_mirror.go, media_copy_job.go).
const (
	autoMirrorSettingsName = "auto-mirror.json"
	autoMirrorStateName    = "auto-mirror-state.json"
	mediaCopyRequestName   = "media-copy-request.json"
	mediaCopyStateName     = "media-copy-state.json"

	// maxCopyAuths: auths one copy request may carry (the engine's limit).
	maxCopyAuths = 400
)

type autoMirrorSettingsJSON struct {
	Enabled  bool  `json:"enabled"`
	RunNowAt int64 `json:"run_now_at,omitempty"`
}

// mediaFilesMu: one writer of the box's media files at a time.
var mediaFilesMu sync.Mutex

func mediaFile(a *API, name string) string {
	return filepath.Join(a.Mover.Engine.VaultDir(), name)
}

func readJSONFile(file string, v any) bool {
	raw, err := os.ReadFile(file)
	return err == nil && json.Unmarshal(raw, v) == nil
}

func writeJSONFileAtomic(file string, v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

// autoMirrorView: the switch and the engine's state, as one answer.
func autoMirrorView(a *API) map[string]any {
	var s autoMirrorSettingsJSON
	readJSONFile(mediaFile(a, autoMirrorSettingsName), &s)
	var st map[string]any
	readJSONFile(mediaFile(a, autoMirrorStateName), &st)
	return map[string]any{"enabled": s.Enabled, "runNowAt": s.RunNowAt, "state": st}
}

func updateAutoMirror(a *API, w http.ResponseWriter, change func(*autoMirrorSettingsJSON)) {
	mediaFilesMu.Lock()
	file := mediaFile(a, autoMirrorSettingsName)
	var s autoMirrorSettingsJSON
	readJSONFile(file, &s)
	change(&s)
	err := writeJSONFileAtomic(file, s)
	mediaFilesMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save the setting"})
		return
	}
	writeJSON(w, http.StatusOK, autoMirrorView(a))
}

func newJobID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func queueMediaCopy(a *API, w http.ResponseWriter, req map[string]any) {
	mediaFilesMu.Lock()
	err := writeJSONFileAtomic(mediaFile(a, mediaCopyRequestName), req)
	mediaFilesMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not queue the job"})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"id": req["id"]})
}

func init() {
	handle("GET /api/box/media/auto-mirror", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		writeJSON(w, http.StatusOK, autoMirrorView(a))
	})
	handle("PUT /api/box/media/auto-mirror", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		var in struct {
			Enabled *bool `json:"enabled"`
		}
		if json.Unmarshal(body, &in) != nil || in.Enabled == nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": `send {"enabled":true|false}`})
			return
		}
		updateAutoMirror(a, w, func(s *autoMirrorSettingsJSON) { s.Enabled = *in.Enabled })
	})
	handle("POST /api/box/media/auto-mirror/run", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		var s autoMirrorSettingsJSON
		readJSONFile(mediaFile(a, autoMirrorSettingsName), &s)
		if !s.Enabled {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "Auto-Mirror is off"})
			return
		}
		updateAutoMirror(a, w, func(s *autoMirrorSettingsJSON) { s.RunNowAt = time.Now().Unix() })
	})
	handle("POST /api/box/media/copy/check", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		queueMediaCopy(a, w, map[string]any{"id": newJobID(), "action": "check", "pubkey": c.Pubkey})
	})
	handle("POST /api/box/media/copy", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, body []byte) {
		var in struct {
			Auths []string `json:"auths"`
		}
		if json.Unmarshal(body, &in) != nil || len(in.Auths) == 0 || len(in.Auths) > maxCopyAuths {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "send 1 to 400 signed upload auths"})
			return
		}
		queueMediaCopy(a, w, map[string]any{"id": newJobID(), "action": "copy", "pubkey": c.Pubkey, "auths": in.Auths})
	})
	handle("GET /api/box/media/copy", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		var st map[string]any
		readJSONFile(mediaFile(a, mediaCopyStateName), &st)
		// Another account's job: its files are not the caller's business.
		if pk, _ := st["pubkey"].(string); pk != c.Pubkey {
			st = nil
		}
		var waiting map[string]any
		readJSONFile(mediaFile(a, mediaCopyRequestName), &waiting)
		pk, _ := waiting["pubkey"].(string)
		writeJSON(w, http.StatusOK, map[string]any{"state": st, "queued": pk == c.Pubkey})
	})
}
