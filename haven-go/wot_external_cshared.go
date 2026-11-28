//go:build cshared

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"log"
	"maps"
	"slices"

	"github.com/barrydeen/haven/pkg/runsafe"
	"github.com/barrydeen/haven/pkg/wot"
	"github.com/nbd-wtf/go-nostr"
)

//export RefreshWotFromRelayC
func RefreshWotFromRelayC(relayURL *C.char) C.int {
	// The WOT tab's refresh for a vault on an outside relay (Citrine): the
	// embedded relay is not running, so RefreshWotC has nothing to run in.
	// 1 when a rebuild started or was already running, else 0. Poll
	// WotRefreshProgressC as for RefreshWotC. The host sets the relay env
	// (DATABASE_PATH and the rest, as for StartRelayC) first.
	defer func() {
		if r := recover(); r != nil {
			log.Printf("RefreshWotFromRelayC: recovered from panic: %v", r)
		}
	}()
	if startExternalWotRefresh(C.GoString(relayURL)) {
		return 1
	}
	return 0
}

// startExternalWotRefresh starts the rebuild for a vault on relayURL. False
// when the embedded relay is up (use RefreshWotC), the env names no data
// directory, or trust is off; true when a rebuild started or one was already
// running. Progress reads through WotRefreshProgressC, as for RefreshWotC.
func startExternalWotRefresh(relayURL string) bool {
	relayLC.mu.Lock()
	if c := relayLC.current.Load(); c != nil || relayLC.isDraining() || hostGetenv("DATABASE_PATH") == "" {
		relayLC.mu.Unlock()
		return false
	}
	// No cycle owns config or the CWD now; this is what StartRelayC would do.
	if err := prepareCSharedEnv(); err != nil {
		relayLC.mu.Unlock()
		log.Println("🚫 WoT rebuild (outside relay):", err)
		return false
	}
	// Taken under the lock: a relay start reloads config beside this build.
	owners := whitelist()
	ownerKeys := slices.Collect(maps.Keys(owners))
	seeds := slices.Clone(config.ImportSeedRelays)
	depth, minFollowers, timeout := effectiveWotDepth(), config.WotMinimumFollowers, config.WotFetchTimeoutSeconds
	cachePath, ttl, userAgent := config.WotCachePath, config.WotCacheTTLMinutes, config.UserAgent
	relayLC.mu.Unlock()

	if len(owners) == 0 {
		return false
	}
	ctx := context.Background()
	p := nostr.NewSimplePool(ctx,
		nostr.WithPenaltyBox(),
		poolDialGate(),
		poolDialSucceeded(),
		nostr.WithRelayOptions(
			nostr.WithRequestHeader{
				"User-Agent": []string{userAgent},
			}),
	)
	model := newFirstRunWotModel(p, owners, seeds, depth, minFollowers, timeout, cachePath, ttl)
	model.LocalFollowLists = func() []*nostr.Event { return followListsFrom(ctx, p, relayURL, ownerKeys) }
	// The saved web is what this one replaces: newcomers are counted against it.
	model.LoadFromCache()
	log.Println("🔄 WoT rebuild with the vault on an outside relay") // no address: it can be a private host
	spawned := false
	started := wot.RefreshNow(ctx, model, func(name string, fn func()) {
		spawned = true
		runsafe.Go(name, func() {
			defer p.Close("wot rebuild done")
			fn()
		})
	})
	if !spawned { // one was already running, or trust is off
		p.Close("wot rebuild not started")
	}
	return started
}
