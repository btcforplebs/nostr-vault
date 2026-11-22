package box

// Import jobs on a box (One Vault spec E5): the Vault Dashboard's Keep it
// full and Still to bring in, run by the engine as on a Mac. The engine
// keeps the jobs in import_jobs.json in the vault folder (haven-go
// import_jobs.go); the box reads it as is and asks the engine to run or
// cancel one through box-jobs.json (haven-go box_jobs.go).
//
//	GET  /api/box/imports         the jobs file: each job's status, stored
//	                              count and unread ranges (still to bring in)  signed in
//	POST /api/box/imports/run     {"job":"replies"} -> {asked, answered, code, message}  signed in
//	POST /api/box/imports/cancel  {"job":"replies"}                                       signed in

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// importJobNames: the engine's jobs (haven-go import_jobs.go jobOrder).
var importJobNames = []string{"setup", "replies", "older_relays", "wider_network", "list_history"}

func init() {
	handle("GET /api/box/imports", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		raw, err := os.ReadFile(filepath.Join(a.Mover.Engine.VaultDir(), "import_jobs.json"))
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, map[string]any{"jobs": []any{}})
			return
		}
		var f map[string]any
		if err != nil || json.Unmarshal(raw, &f) != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the vault's import jobs file can't be read"})
			return
		}
		writeJSON(w, http.StatusOK, f)
	})
	for _, action := range []string{"run", "cancel"} {
		handle("POST /api/box/imports/"+action, SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
			var req struct {
				Job string `json:"job"`
			}
			if json.Unmarshal(body, &req) != nil || !slices.Contains(importJobNames, strings.TrimSpace(req.Job)) {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "job must be one of " + strings.Join(importJobNames, ", ")})
				return
			}
			ans, err := askEngine(a.Mover.Engine.VaultDir(), "import", map[string]any{"action": action, "job": strings.TrimSpace(req.Job)})
			if err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
				return
			}
			ans.Message = importMessage(action, ans)
			writeJSON(w, http.StatusOK, ans)
		})
	}
}

func importMessage(action string, a EngineAnswer) string {
	if !a.Answered {
		return "Asked. The vault does it as soon as it is running."
	}
	if action == "cancel" {
		return map[int]string{0: "Stopping.", 1: "That job isn't running."}[a.Code]
	}
	return map[int]string{0: "Started.", 1: "The vault doesn't know that job.", 2: "Another job is running; try again when it ends.", 3: "The vault is still starting; try again in a moment."}[a.Code]
}

// EngineAnswer: whether the engine took a request yet, and its code
// (haven-go box_jobs.go boxJobDone).
type EngineAnswer struct {
	Asked    bool   `json:"asked"`
	Answered bool   `json:"answered"`
	Code     int    `json:"code"`
	Message  string `json:"message,omitempty"`
}

var (
	engineAskMu sync.Mutex
	// engineAskWait: how long a route waits for the engine's answer (it
	// looks every 2 s). Longer, and the request is left for it to do.
	engineAskWait = 5 * time.Second
	engineAskPoll = 100 * time.Millisecond
)

// askEngine files a request for area ("import", "wot", "blocklist") in the
// vault's box-jobs.json under a new seq, then waits a little for the
// engine's answer in box-jobs-state.json. The file keeps every area's last
// request, so one area's ask never drops another's.
func askEngine(vaultDir, area string, ask map[string]any) (EngineAnswer, error) {
	engineAskMu.Lock()
	asks := map[string]map[string]any{}
	if raw, err := os.ReadFile(filepath.Join(vaultDir, "box-jobs.json")); err == nil {
		_ = json.Unmarshal(raw, &asks)
	}
	seq := int64(0)
	if prev, ok := asks[area]["seq"].(float64); ok {
		seq = int64(prev)
	}
	if done := engineDone(vaultDir, area); done.Seq > seq {
		seq = done.Seq
	}
	seq++
	next := map[string]any{"seq": seq}
	for k, v := range ask {
		next[k] = v
	}
	asks[area] = next
	err := writeJSONAtomic(filepath.Join(vaultDir, "box-jobs.json"), asks)
	engineAskMu.Unlock()
	if err != nil {
		return EngineAnswer{}, err
	}
	for until := time.Now().Add(engineAskWait); time.Now().Before(until); time.Sleep(engineAskPoll) {
		if d := engineDone(vaultDir, area); d.Seq >= seq {
			return EngineAnswer{Asked: true, Answered: true, Code: d.Code}, nil
		}
	}
	return EngineAnswer{Asked: true}, nil
}

type engineDoneEntry struct {
	Seq  int64 `json:"seq"`
	Code int   `json:"code"`
	At   int64 `json:"at,omitempty"`
}

// engineState is box-jobs-state.json, what the engine wrote; empty before it
// wrote one.
func engineState(vaultDir string) map[string]json.RawMessage {
	out := map[string]json.RawMessage{}
	if raw, err := os.ReadFile(filepath.Join(vaultDir, "box-jobs-state.json")); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

func engineDone(vaultDir, area string) engineDoneEntry {
	var d engineDoneEntry
	_ = json.Unmarshal(engineState(vaultDir)[area], &d)
	return d
}

// writeJSONAtomic writes v as JSON to path through writeFileAtomic
// (devices_engine.go), so the engine never reads half a file.
func writeJSONAtomic(path string, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, body, 0o600)
}
