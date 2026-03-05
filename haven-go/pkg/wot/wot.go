package wot

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"
)

type Model interface {
	Has(ctx context.Context, pubkey string) bool
}

type Refresher interface {
	Refresh(ctx context.Context)
}

type Initializer interface {
	Init(ctx context.Context)
}

var wotInstance atomic.Value

// readyCh is closed once Initialize() finishes, signalling that the WoT
// graph is fully populated and Has() calls are reliable.
// Reset via ResetReady() before each Initialize() cycle (e.g. iOS relay restart).
var readyCh = make(chan struct{})

func GetInstance() Model {
	val := wotInstance.Load()
	if val == nil {
		return nil
	}
	return val.(Model)
}

// ResetReady creates a fresh ready channel. Call before Initialize()
// when the relay is restarted (e.g. iOS stop/start cycle).
func ResetReady() {
	readyCh = make(chan struct{})
}

// WaitReady blocks until Initialize() has completed.
func WaitReady(ctx context.Context) {
	select {
	case <-readyCh:
	case <-ctx.Done():
	}
}

func Initialize(ctx context.Context, model Model) {
	wotInstance.Store(model)
	if initializer, ok := model.(Initializer); ok {
		slog.Info("🌐 Initializing WoT", "model", fmt.Sprintf("%T", model))
		initializer.Init(ctx)
		slog.Info("✅ WoT initialized")
	}
	close(readyCh)
}

func PeriodicRefresh(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			instance := GetInstance()
			if refresher, ok := instance.(Refresher); ok {
				slog.Info("🌐 Refreshing WoT")
				refresher.Refresh(ctx)
				slog.Info("✅ WoT refreshed")
			}
		}
	}
}
