//go:build !(js && wasm)

package main

// The trust rank hand-off (discovery engine phase 2): an owner's own
// devices get wot_rank_<account>.json from their Haven during the catch-up
// (docs/MESH_COPY_V2_CONTRACT.md §6.5). It rides the copy token, which is
// bound to a paired device's mesh key; the account key is never used or
// asked for, and nothing is signed. Only rows over trustrank.HandoffFloor
// travel. The whole trimmed file is sent when it is newer than the
// device's; there is no row-by-row diff.

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"slices"
	"strconv"

	"github.com/barrydeen/haven/pkg/trustrank"
)

// copyTrustMaxSize bounds the copy a device reads (the 2026-11-22 map is
// about 2.2 MB over the floor).
const copyTrustMaxSize = 64 << 20

// serveSyncTrust is GET /copy/v2/sync/trust?account=<hex>&since=<builtAt>,
// behind the device's bearer. 404: not an account this Haven ranks, or no
// result yet. 204: the device's copy (since) is as new as this one.
func (s *copyServer) serveSyncTrust(w http.ResponseWriter, r *http.Request, tokenHash string) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	q := r.URL.Query()
	account := q.Get("account")
	if !copyIsHex(account, 64) || !slices.Contains(trustRankAccounts(), account) {
		http.NotFound(w, r)
		return
	}
	// "Nothing newer" is answered from the start of the file: most catch-ups
	// find the device up to date, and reading every row for that cost about
	// 75 MB a request on a 78,855-row map (Tron, #2409).
	built, err := trustrank.ResultBuiltAt(trustRankDir(), account)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if since, _ := strconv.ParseInt(q.Get("since"), 10, 64); since >= built {
		vaultHandoffAsked(account, s.tokenDevice(tokenHash), 0)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	f, err := trustrank.ReadResult(trustRankDir(), account)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	// A copy this Haven itself got from another one is already trimmed.
	if f.Floor < trustrank.HandoffFloor {
		f = f.Handoff(trustrank.HandoffFloor)
	}
	vaultHandoffAsked(account, s.tokenDevice(tokenHash), f.BuiltAt)
	copyJSON(w, http.StatusOK, f)
}

// trustRankTakesCopy: whether this device keeps a Haven's result. One that
// ranks for itself (a Mac, a box) keeps its own.
var trustRankTakesCopy = func() bool {
	return !trustRankWanted(runtime.GOOS, hostGetenv("TRUST_RANK"))
}

// copyTrustKeepDir: where a device keeps the copy (a test's A and B share
// one process, so it gives B its own).
var copyTrustKeepDir = trustRankDir

// syncTrust asks A for each own account's result and keeps a newer one.
// It never fails the catch-up: an A from before this answers 404. Returns
// how many accounts got a new copy.
func (c *copyClient) syncTrust(ctx context.Context) int {
	if !trustRankTakesCopy() {
		return 0
	}
	dir, got := copyTrustKeepDir(), 0
	pruneTrustRank(dir)
	for _, account := range trustRankAccounts() {
		since := int64(0)
		if mine, err := trustrank.ReadResult(dir, account); err == nil {
			since = mine.BuiltAt
		} else if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, trustrank.ErrBadResult) {
			continue
		}
		resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/trust?account="+account+"&since="+strconv.FormatInt(since, 10), nil, nil)
		if err != nil {
			return got
		}
		raw, rerr := io.ReadAll(io.LimitReader(resp.Body, copyTrustMaxSize+1))
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || rerr != nil || len(raw) > copyTrustMaxSize {
			continue
		}
		f, err := trustrank.CheckHandoff(raw, account)
		if err != nil || f.BuiltAt <= since {
			slog.Warn("trust rank copy refused", "account", account[:8])
			continue
		}
		if err := trustrank.WriteHandoff(dir, f); err != nil {
			slog.Warn("trust rank copy not kept", "err", err)
			continue
		}
		got++
		slog.Info("trust rank copy kept", "account", account[:8], "people", len(f.People), "bytes", len(raw))
	}
	return got
}

// trustRankAccountsSure: the accounts ranked or kept here, and whether that
// list comes from the app's account file. Without the file the list falls
// back to the owner alone (fail closed), which says nothing about the other
// accounts, so nothing is pruned on it.
func trustRankAccountsSure() ([]string, bool) {
	raw, err := os.ReadFile(copyAccountsFile)
	if err != nil {
		return nil, false
	}
	if _, why := copyAccountsRefusal(raw); why != "" {
		return nil, false
	}
	return trustRankAccounts(), true
}

// pruneTrustRank removes the result (and, on a Haven, the crawl checkpoint)
// of every account that has signed out of this device (Tron, #2409): on a
// phone its copy from the Haven, on a Mac or box its own result. The shared
// list store stays.
func pruneTrustRank(dir string) {
	keep, sure := trustRankAccountsSure()
	if !sure {
		return
	}
	for _, a := range trustrank.PruneAccounts(dir, keep) {
		slog.Info("trust rank: signed-out account's result removed", "account", a[:8])
	}
}
