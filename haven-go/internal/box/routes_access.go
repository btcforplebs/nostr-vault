package box

// Who can reach the box's vault (One Vault spec E5): rebuild the web of
// trust now, the block list, and Force restart. The engine rebuilds and
// takes the block list when asked through box-jobs.json (routes_jobs.go,
// haven-go box_jobs.go).
//
//	GET  /api/box/trust          {trust: the rebuild's progress, last: {seq, code, at}}  signed in
//	POST /api/box/trust/refresh  -> EngineAnswer (code 0 started, 1 trust is off)        signed in
//	GET  /api/box/blocklist      {npubs: [...]}                                          signed in
//	POST /api/box/blocklist      {npubs: [...]} -> {npubs, blocked, answered}            first account
//	POST /api/box/restart        -> 202 the job (backup.go)                              first account
//
// The block list is the box's, for every account on it, so only the first
// account changes it (as on a Mac, where one list covers every account).

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/nbd-wtf/go-nostr/nip19"
)

const blocklistMax = 10_000

func init() {
	handle("GET /api/box/trust", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		st := engineState(a.Mover.Engine.VaultDir())
		trust := json.RawMessage(`{}`)
		if t, ok := st["trust"]; ok {
			trust = t
		}
		writeJSON(w, http.StatusOK, map[string]any{"trust": trust, "last": engineDone(a.Mover.Engine.VaultDir(), "wot")})
	})
	handle("POST /api/box/trust/refresh", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		ans, err := askEngine(a.Mover.Engine.VaultDir(), "wot", nil)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		ans.Message = map[bool]string{true: map[int]string{0: "Rebuilding who can reach you.", 1: "Trust is off on this vault."}[ans.Code], false: "Asked. The vault rebuilds as soon as it is running."}[ans.Answered]
		writeJSON(w, http.StatusOK, ans)
	})
	handle("GET /api/box/blocklist", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		npubs, err := readBlocklist(a.Mover.Engine.VaultDir())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"npubs": npubs})
	})
	handle("POST /api/box/blocklist", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		var req struct {
			Npubs []string `json:"npubs"`
		}
		if json.Unmarshal(body, &req) != nil || req.Npubs == nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "send {\"npubs\": [...]}"})
			return
		}
		npubs, err := cleanBlocklist(req.Npubs)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		dir := a.Mover.Engine.VaultDir()
		if err := writeJSONAtomic(filepath.Join(dir, "blacklisted_npubs.json"), npubs); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		ans, err := askEngine(dir, "blocklist", nil)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		out := map[string]any{"npubs": npubs, "answered": ans.Answered}
		if ans.Answered {
			out["blocked"] = ans.Code
		}
		writeJSON(w, http.StatusOK, out)
	})
	handle("POST /api/box/restart", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		job, err := a.Mover.Restart()
		answerEngineJob(w, job, err)
	})
}

// readBlocklist: the vault's blacklisted_npubs.json (the engine's
// BLACKLISTED_NPUBS_FILE); none yet is an empty list.
func readBlocklist(vaultDir string) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(vaultDir, "blacklisted_npubs.json"))
	if errors.Is(err, os.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []string{}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, errors.New("the vault's block list can't be read")
	}
	return out, nil
}

// cleanBlocklist: npubs only, each once, in the order given. A secret key
// is refused with the same plain words as everywhere else on the box.
func cleanBlocklist(in []string) ([]string, error) {
	if len(in) > blocklistMax {
		return nil, errors.New("too many keys in one block list")
	}
	out, seen := []string{}, map[string]bool{}
	for _, s := range in {
		s = strings.TrimSpace(s)
		if strings.HasPrefix(s, "nsec1") {
			return nil, errors.New("that's a secret key; never paste it anywhere. A block list takes public keys (npub1…)")
		}
		if prefix, _, err := nip19.Decode(s); err != nil || prefix != "npub" {
			return nil, errors.New("not a public key (npub1…): " + s)
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out, nil
}
