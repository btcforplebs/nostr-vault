//go:build !(js && wasm)

package main

// The desktop Vault's status read (Logen 2026-11-23): what the trust rank
// crawler (trust_rank_job.go), the distant posts job (distant_posts_job.go)
// and the rank hand-off (copyv2_trust.go) are doing, for the Mac menu bar
// and Your Space (VaultStatusC), and for the owner's own paired devices
// over the mesh (copyv2_status.go). It reads only what the jobs already
// keep, plus a small marks file for the distant fetch and the hand-offs.
// It signs nothing and publishes nothing.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/barrydeen/haven/pkg/trustrank"
)

// vaultStatus is the read's answer. Times are Unix seconds, 0 for never.
type vaultStatus struct {
	Version int   `json:"version"`
	At      int64 `json:"at"`
	// State: "running", "paused", "idle", or "off" (this process never
	// ranks: a phone, or TRUST_RANK=off).
	State string `json:"state"`
	// PausedWhy, when paused: "app" (the Mac window is open, or Run in
	// background is off) or "busy" (an import or copy is running, or ran
	// in the last minute).
	PausedWhy string               `json:"pausedWhy,omitempty"`
	Accounts  []vaultAccountStatus `json:"accounts"`
}

type vaultAccountStatus struct {
	Account string `json:"account"`
	// Running: this account's pass is the one being read now.
	Running bool `json:"running"`
	// Ring being read (1 = the owner's follows), and the place in it; set
	// while running, or kept from a pass that was paused halfway.
	Ring      int  `json:"ring,omitempty"`
	RingDone  int  `json:"ringDone,omitempty"`
	RingTotal int  `json:"ringTotal,omitempty"`
	Refresh   bool `json:"refresh,omitempty"`
	// ListsRead: lists read since this pass started or resumed here.
	ListsRead int `json:"listsRead,omitempty"`
	// Cut: a pass stopped halfway and waits to go on.
	Cut bool `json:"cut,omitempty"`
	// FinishedAt: the last finished pass, full or refresh.
	FinishedAt int64 `json:"finishedAt"`
	FullAt     int64 `json:"fullAt,omitempty"`
	RefreshAt  int64 `json:"refreshAt,omitempty"`
	Capped     bool  `json:"capped,omitempty"`
	// Result: the result file's counts; nil before the first one.
	Result *trustrank.Summary `json:"result,omitempty"`
	// DistantAtBar: distant connections at or over the result's view bar
	// (a screen with its own slider counts Result.DistantByShown instead).
	DistantAtBar int `json:"distantAtBar"`
	// Distant posts: the last round that fetched for this account.
	DistantFetchAt     int64 `json:"distantFetchAt,omitempty"`
	DistantFetchPeople int   `json:"distantFetchPeople,omitempty"`
	DistantFetchNew    int   `json:"distantFetchNew,omitempty"`
	// Handoffs: each paired device's last ask for the ranking.
	Handoffs []vaultHandoff `json:"handoffs"`
}

// vaultHandoff: TookAt is the last time the device was sent the ranking
// (BuiltAt is the result it got); CheckedAt the last time it asked at all.
type vaultHandoff struct {
	Device    string `json:"device"` // mesh key, hex
	Role      string `json:"role,omitempty"`
	TookAt    int64  `json:"tookAt,omitempty"`
	BuiltAt   int64  `json:"builtAt,omitempty"`
	CheckedAt int64  `json:"checkedAt"`
}

// vaultPass: the running pass, in memory.
type vaultPass struct {
	account                 string
	ring, done, total, read int
	refresh                 bool
}

var vaultLive = struct {
	sync.Mutex
	vaultPass
}{}

// vaultPassBegin / vaultPassProgress / vaultPassEnd: the crawler's pass
// for account (runTrustRank).
func vaultPassBegin(account string, refresh bool) {
	vaultLive.Lock()
	vaultLive.vaultPass = vaultPass{account: account, refresh: refresh}
	vaultLive.Unlock()
}

func vaultPassProgress(ring, done, total int) {
	vaultLive.Lock()
	vaultLive.ring, vaultLive.done, vaultLive.total = ring, done, total
	vaultLive.read++
	vaultLive.Unlock()
}

func vaultPassEnd() {
	vaultLive.Lock()
	vaultLive.account = ""
	vaultLive.Unlock()
}

// The marks file: the distant fetch and the hand-offs, kept so a restart
// does not show "never".
const vaultMarksFile = "vault_status_marks.json"

type vaultMarks struct {
	Distant  map[string]vaultDistantMark        `json:"distant"`
	Handoffs map[string]map[string]vaultHandoff `json:"handoffs"` // account -> device -> mark
}

type vaultDistantMark struct {
	At     int64 `json:"at"`
	People int   `json:"people"`
	New    int   `json:"new"`
}

var vaultMarksMu sync.Mutex

// vaultMarksDir: where the marks file lives; trustRankDir unless a test sets it.
var vaultMarksDir = trustRankDir

func loadVaultMarks() vaultMarks {
	m := vaultMarks{}
	if raw, err := os.ReadFile(filepath.Join(vaultMarksDir(), vaultMarksFile)); err == nil {
		_ = json.Unmarshal(raw, &m)
	}
	if m.Distant == nil {
		m.Distant = map[string]vaultDistantMark{}
	}
	if m.Handoffs == nil {
		m.Handoffs = map[string]map[string]vaultHandoff{}
	}
	return m
}

func saveVaultMarks(m vaultMarks) {
	raw, err := json.Marshal(m)
	if err != nil {
		return
	}
	path := filepath.Join(vaultMarksDir(), vaultMarksFile)
	if os.WriteFile(path+".tmp", raw, 0o600) == nil {
		_ = os.Rename(path+".tmp", path)
	}
}

func updateVaultMarks(change func(*vaultMarks) bool) {
	vaultMarksMu.Lock()
	defer vaultMarksMu.Unlock()
	m := loadVaultMarks()
	if change(&m) {
		saveVaultMarks(m)
	}
}

// vaultNow is the marks' clock (tests).
var vaultNow = time.Now

// pruneVaultMarks drops the marks of accounts that signed out of this
// device (pruneTrustRank, which runs it only when the account list is sure).
func pruneVaultMarks(keep []string) {
	kept := map[string]bool{}
	for _, a := range keep {
		kept[a] = true
	}
	updateVaultMarks(func(m *vaultMarks) bool {
		changed := false
		for a := range m.Distant {
			if !kept[a] {
				delete(m.Distant, a)
				changed = true
			}
		}
		for a := range m.Handoffs {
			if !kept[a] {
				delete(m.Handoffs, a)
				changed = true
			}
		}
		return changed
	})
}

// vaultForgetDevice drops an unpaired device's hand-off marks.
func vaultForgetDevice(device string) {
	device = strings.ToLower(device)
	updateVaultMarks(func(m *vaultMarks) bool {
		changed := false
		for _, per := range m.Handoffs {
			if _, ok := per[device]; ok {
				delete(per, device)
				changed = true
			}
		}
		return changed
	})
}

// vaultDistantFetched: a distant posts round fetched for account.
func vaultDistantFetched(account string, people, kept int) {
	updateVaultMarks(func(m *vaultMarks) bool {
		m.Distant[account] = vaultDistantMark{At: vaultNow().Unix(), People: people, New: kept}
		return true
	})
}

// vaultHandoffAsked: device asked for account's ranking; builtAt > 0 when
// it was sent one. A hand-off that was only checked is written at most
// hourly, since devices ask at every catch-up.
func vaultHandoffAsked(account, device string, builtAt int64) {
	if device == "" {
		return
	}
	now := vaultNow().Unix()
	vaultMarksMu.Lock()
	defer vaultMarksMu.Unlock()
	m := loadVaultMarks()
	per := m.Handoffs[account]
	if per == nil {
		per = map[string]vaultHandoff{}
		m.Handoffs[account] = per
	}
	h := per[device]
	if builtAt == 0 && now-h.CheckedAt < 3600 {
		return
	}
	h.Device, h.CheckedAt = device, now
	if builtAt > 0 {
		h.TookAt, h.BuiltAt = now, builtAt
	}
	per[device] = h
	saveVaultMarks(m)
}

// vaultSummaries caches each account's summary by its result's builtAt, so
// a status read decodes a result file once.
var vaultSummaries = struct {
	sync.Mutex
	by map[string]trustrank.Summary
}{by: map[string]trustrank.Summary{}}

func vaultResultSummary(dir, account string) *trustrank.Summary {
	built, err := trustrank.ResultBuiltAt(dir, account)
	if err != nil {
		return nil
	}
	key := dir + "|" + account
	vaultSummaries.Lock()
	s, ok := vaultSummaries.by[key]
	vaultSummaries.Unlock()
	if ok && s.BuiltAt == built {
		return &s
	}
	f, err := trustrank.ReadResult(dir, account)
	if err != nil {
		return nil
	}
	s = f.Summarize()
	vaultSummaries.Lock()
	vaultSummaries.by[key] = s
	vaultSummaries.Unlock()
	return &s
}

// vaultPausedWhy: why the crawler may not run now, "" when it may.
func vaultPausedWhy(cshared, host, busy bool) string {
	switch {
	case cshared && !host:
		return "app"
	case busy:
		return "busy"
	}
	return ""
}

// vaultStatusCshared: whether this process is the app library (the Mac
// window decides); set by the cshared build.
var vaultStatusCshared = false

// readVaultStatus builds the answer now.
func readVaultStatus() vaultStatus {
	return buildVaultStatus(trustRankDir(), trustRankAccounts(), time.Now(),
		trustRankWanted(runtime.GOOS, hostGetenv("TRUST_RANK")),
		vaultPausedWhy(vaultStatusCshared, trustRankHost.Load(), realWorkRunning()),
		meshDevices.pairedRoles())
}

// pairedRoles: the paired devices now, hex -> role.
func (m *meshDeviceSet) pairedRoles() map[string]string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make(map[string]string, len(m.devices))
	for hex, role := range m.devices {
		out[hex] = role
	}
	return out
}

func buildVaultStatus(dir string, accounts []string, now time.Time, wanted bool, why string, paired map[string]string) vaultStatus {
	out := vaultStatus{Version: 1, At: now.Unix(), State: "idle", Accounts: []vaultAccountStatus{}}
	vaultLive.Lock()
	live := vaultLive.vaultPass
	vaultLive.Unlock()
	switch {
	case !wanted:
		out.State = "off"
	case live.account != "" && why == "":
		out.State = "running"
	case why != "":
		out.State, out.PausedWhy = "paused", why
	}
	vaultMarksMu.Lock()
	marks := loadVaultMarks()
	vaultMarksMu.Unlock()
	for _, account := range accounts {
		a := vaultAccountStatus{Account: account, Handoffs: []vaultHandoff{}}
		st := trustrank.LoadState(dir, account)
		a.FullAt, a.RefreshAt, a.Capped = st.FullAt, st.RefreshAt, st.Capped
		a.FinishedAt = max(st.FullAt, st.RefreshAt)
		if cutPass(st) {
			a.Cut, a.Ring, a.RingDone, a.Refresh = true, st.Hop, st.Next, st.Refresh
		}
		if wanted && live.account == account {
			a.Running = out.State == "running"
			a.Ring, a.RingDone, a.RingTotal = live.ring, live.done, live.total
			a.ListsRead, a.Refresh = live.read, live.refresh
		}
		if s := vaultResultSummary(dir, account); s != nil {
			a.Result = s
			a.DistantAtBar = s.DistantAtBar(s.ViewBar)
		}
		if d, ok := marks.Distant[account]; ok {
			a.DistantFetchAt, a.DistantFetchPeople, a.DistantFetchNew = d.At, d.People, d.New
		}
		for device, h := range marks.Handoffs[account] {
			role, ok := paired[device]
			if !ok {
				continue // unpaired since: not one of this owner's devices now
			}
			h.Role = role
			a.Handoffs = append(a.Handoffs, h)
		}
		sort.Slice(a.Handoffs, func(i, j int) bool { return a.Handoffs[i].Device < a.Handoffs[j].Device })
		out.Accounts = append(out.Accounts, a)
	}
	return out
}
