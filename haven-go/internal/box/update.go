package box

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// POST /api/box/update. The box cannot replace its own container image, so
// it hands the request to whoever can:
//
//   - NV_UPDATE_HOOK set: that program runs (detached from the request,
//     10 minute limit) with NV_UPDATE_REQUESTED_AT in its environment.
//   - otherwise: box/update-request.json is written for the container side
//     (a host timer or a watcher) to act on and delete.

// UpdateResult is the API's answer.
type UpdateResult struct {
	Queued bool   `json:"queued"`
	Via    string `json:"via"` // "hook" or "file"
	At     int64  `json:"requestedAt"`
}

type Updater struct {
	Hook   string
	BoxDir string

	mu      sync.Mutex
	running bool
}

var ErrUpdateBusy = errors.New("an update is already running")

func (u *Updater) Request() (UpdateResult, error) {
	now := time.Now().Unix()
	if u.Hook == "" {
		b, _ := json.Marshal(map[string]int64{"requestedAt": now})
		if err := os.MkdirAll(u.BoxDir, 0o700); err != nil {
			return UpdateResult{}, err
		}
		if err := os.WriteFile(filepath.Join(u.BoxDir, "update-request.json"), b, 0o600); err != nil {
			return UpdateResult{}, err
		}
		return UpdateResult{Queued: true, Via: "file", At: now}, nil
	}
	u.mu.Lock()
	if u.running {
		u.mu.Unlock()
		return UpdateResult{}, ErrUpdateBusy
	}
	u.running = true
	u.mu.Unlock()
	go func() {
		defer func() { u.mu.Lock(); u.running = false; u.mu.Unlock() }()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, u.Hook)
		cmd.Env = append(os.Environ(), "NV_UPDATE_REQUESTED_AT="+itoa64(now))
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		_ = cmd.Run()
	}()
	return UpdateResult{Queued: true, Via: "hook", At: now}, nil
}
