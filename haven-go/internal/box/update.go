package box

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"sync"
	"time"
)

// POST /api/box/update. The box cannot replace its own container image, so
// it hands the request to whoever can:
//
//   - NV_UPDATE_HOOK set: that program runs (detached from the request,
//     10 minute limit) with NV_UPDATE_REQUESTED_AT in its environment.
//   - otherwise nothing on the host can do it (the packages set up no hook or
//     watcher), so the answer is Manual: install the newer package. Nothing is
//     written, and the box never says an update started.

//   - NV_UPDATE_VIA set (startos, umbrel): the store updates the box, so the
//     answer is Managed with Via naming the store, and nothing runs.

// UpdateResult is the API's answer.
type UpdateResult struct {
	// The screens' fields (api.js). To and rollback are the container
	// side's to know; the box leaves them out rather than guess.
	Started bool   `json:"started"`
	From    string `json:"from,omitempty"`

	// Manual: nothing here can run an update; the owner installs the newer package.
	Manual bool `json:"manual,omitempty"`

	// Managed: a store (Via) updates the box; the owner updates it there.
	Managed bool `json:"managed,omitempty"`

	Queued bool   `json:"queued"`
	Via    string `json:"via"` // "hook", "manual", or the store: "startos", "umbrel"
	At     int64  `json:"requestedAt"`
}

type Updater struct {
	Hook   string
	BoxDir string
	Store  string // NV_UPDATE_VIA; set, it wins over Hook

	mu      sync.Mutex
	running bool
}

var ErrUpdateBusy = errors.New("an update is already running")

func (u *Updater) Request() (UpdateResult, error) {
	now := time.Now().Unix()
	if u.Store != "" {
		return UpdateResult{Managed: true, Via: u.Store, At: now}, nil
	}
	if u.Hook == "" {
		return UpdateResult{Manual: true, Via: "manual", At: now}, nil
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
	return UpdateResult{Started: true, Queued: true, Via: "hook", At: now}, nil
}
