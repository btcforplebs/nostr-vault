package box

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The box catching up from the owner's other vaults (sync.go). The box
// copies with its own mesh key, so who asks signs nothing. Any signed-in
// account may see that it runs and ask it to catch up now; only the first
// account sees the owner's devices and starts a first copy, which makes that
// vault zip its whole vault (Tron #2385 M1, L2).
func init() {
	handle("GET /api/box/sync", SignedIn, func(a *API, w http.ResponseWriter, r *http.Request, c Caller, _ []byte) {
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		rep, err := a.Sync.Report(r.Context(), c.First)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, rep)
	})
	handle("POST /api/box/sync/now", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		device, ok := syncDeviceArg(w, body, false)
		if !ok {
			return
		}
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		if wait := a.Sync.allowNow(device, time.Now()); wait > 0 {
			w.Header().Set("Retry-After", strconv.Itoa(int(wait.Round(time.Second)/time.Second)))
			writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "a catch-up was just asked for; try again shortly", "retryAfter": int(wait.Round(time.Second) / time.Second)})
			return
		}
		if err := a.Sync.Now(device); err != nil {
			syncError(w, err)
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "device": device})
	})
	handle("POST /api/box/sync/first", FirstAccount, func(a *API, w http.ResponseWriter, r *http.Request, _ Caller, body []byte) {
		device, ok := syncDeviceArg(w, body, true)
		if !ok {
			return
		}
		if a.Sync == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box does not catch up from other vaults"})
			return
		}
		if err := a.Sync.First(r.Context(), device); err != nil {
			syncError(w, err)
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "device": device})
	})
}

// syncDeviceArg reads {"device":"npub1…"}; an empty body is "all" unless
// required.
func syncDeviceArg(w http.ResponseWriter, body []byte, required bool) (string, bool) {
	var in struct {
		Device string `json:"device"`
	}
	if len(strings.TrimSpace(string(body))) > 0 {
		if err := json.Unmarshal(body, &in); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body is not JSON"})
			return "", false
		}
	}
	in.Device = strings.TrimSpace(in.Device)
	if in.Device == "" && !required {
		return "", true
	}
	_, npub, err := ParseOwner(in.Device)
	if err != nil || !strings.HasPrefix(in.Device, "npub1") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "device must be a device's npub"})
		return "", false
	}
	return npub, true
}

// allowNow throttles Sync now (Tron #2385 low): one ask per device, and one
// for all, per NowEvery; a recent ask for all also covers each device. It
// records an allowed ask; a refused one returns how long to wait.
func (s *Syncer) allowNow(device string, now time.Time) time.Duration {
	every := orDur(s.NowEvery, time.Minute)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lastNow == nil {
		s.lastNow = map[string]time.Time{}
	}
	wait := time.Duration(0)
	for _, k := range []string{"", device} {
		if at, ok := s.lastNow[k]; ok {
			if left := every - now.Sub(at); left > wait {
				wait = left
			}
		}
	}
	if wait > 0 {
		return wait
	}
	s.lastNow[device] = now
	return 0
}

func syncError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotPaired):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
	case errors.Is(err, ErrCopyBusy), errors.Is(err, ErrHasCopy):
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
	default:
		// nv-mesh could not reach it, or the engine is down.
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
	}
}
