package main

import (
	"fmt"
	"log"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// One import cycle's outcome, printed as ONE line at its very end so every
// app can tell a finished import from a cut, failed or cancelled one
// (audits RESEARCH/NV_IMPORT_AUDIT_*_2026_11_05.md: every platform used to
// call all of them "Import Complete!"):
//
//	IMPORT_RESULT status=<complete|partial|failed|cancelled> reason=<r[,r…]> owner=<n> tagged=<n> relays=<reached>/<seeds> other_vault=<none|reached|not_reached>
//
//   - status=complete: reason=ok. Every step ran to its end.
//   - status=partial: it ran, but some notes may be missing. Reasons (any
//     of): other_vault_not_reached, walk_deadline, relay_stopped_partway,
//     relay_dropped, notes_missing, notes_failed, tagged_timeout.
//   - status=failed: nothing (or not the import) ran. One reason:
//     already_running, still_draining (both worth a retry), config,
//     no_seed_relay, db_init, panic.
//   - status=cancelled: reason=cancelled (StopRelayC during the import).
//   - owner / tagged: notes the run reported storing (owner notes, then
//     replies/mentions/zaps). 0 when that step never ran.
//   - relays: seed relays that answered the connect check / all seeds.
//   - other_vault: the paired device read for "Copy from my other vault"
//     (IMPORT_OTHER_VAULT_RELAY), or none.
//
// Keys may be added later; parsers must ignore keys they don't know.
// GetImportResultC returns the same line (without the log timestamp) after
// StartRelayC(1) returns, so a host need not catch it in the log stream.

const importResultMarker = "IMPORT_RESULT"

// importOtherVaultEnv names the seed relay that is the paired other vault,
// set by the app for the copy and "" otherwise (the env lives across runs).
const importOtherVaultEnv = "IMPORT_OTHER_VAULT_RELAY"

type importOutcome struct {
	mu         sync.Mutex
	failReason string
	cancelled  bool
	partial    []string
	owner      int
	tagged     int
	seeds      int
	reached    int
	otherVault string // "none", "reached" or "not_reached"
}

// currentImport is the outcome being collected, nil outside an import.
var currentImport atomic.Pointer[importOutcome]

// lastImportResult is the last result line, for GetImportResultC.
var lastImportResult atomic.Value // string

func newImportOutcome() *importOutcome {
	return &importOutcome{otherVault: "none"}
}

func (o *importOutcome) fail(reason string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.failReason == "" {
		o.failReason = reason
	}
}

func (o *importOutcome) cancel() {
	o.mu.Lock()
	o.cancelled = true
	o.mu.Unlock()
}

func (o *importOutcome) cut(reason string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if !slices.Contains(o.partial, reason) {
		o.partial = append(o.partial, reason)
	}
}

// relaysChecked records ensureImportRelays' answer: all seeds, the reachable
// ones, and whether the other vault (if any) was among them.
func (o *importOutcome) relaysChecked(seeds, reachable []string, otherVault string) {
	o.mu.Lock()
	o.seeds = len(seeds)
	o.reached = len(reachable)
	o.mu.Unlock()
	if otherVault == "" {
		return
	}
	if slices.Contains(reachable, otherVault) {
		o.mu.Lock()
		o.otherVault = "reached"
		o.mu.Unlock()
		return
	}
	o.mu.Lock()
	o.otherVault = "not_reached"
	o.mu.Unlock()
	o.cut("other_vault_not_reached")
}

var (
	ownerDoneRe   = regexp.MustCompile(`owner note import complete! Imported (\d+) notes`)
	taggedCountRe = regexp.MustCompile(`imported (\d+) tagged notes`)
)

// observe reads the import's own log lines (import.go and import_owner.go
// are not changed here) for its counts and for the signs of a cut run.
func (o *importOutcome) observe(line string) {
	switch {
	case strings.Contains(line, importResultMarker):
		return
	case strings.Contains(line, "failed to init import DBs"):
		o.fail("db_init")
	case strings.Contains(line, "window by window passed"):
		o.cut("walk_deadline")
	case strings.Contains(line, "stopped partway through"):
		o.cut("relay_stopped_partway")
	case strings.Contains(line, "not asking it again"):
		o.cut("relay_dropped")
	case strings.Contains(line, "still missing after asking again"):
		o.cut("notes_missing")
	case strings.Contains(line, "Failed to import") && strings.Contains(line, "notes"):
		o.cut("notes_failed")
	case strings.Contains(line, "while importing tagged notes"):
		o.cut("tagged_timeout")
	}
	if m := ownerDoneRe.FindStringSubmatch(line); m != nil {
		n, _ := strconv.Atoi(m[1])
		o.mu.Lock()
		o.owner = n
		o.mu.Unlock()
	}
	if m := taggedCountRe.FindStringSubmatch(line); m != nil {
		n, _ := strconv.Atoi(m[1])
		o.mu.Lock()
		o.tagged = n
		o.mu.Unlock()
	}
}

// status orders the outcomes: failed > cancelled > partial > complete.
func (o *importOutcome) status() (status, reason string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	switch {
	case o.failReason != "":
		return "failed", o.failReason
	case o.cancelled:
		return "cancelled", "cancelled"
	case len(o.partial) > 0:
		return "partial", strings.Join(o.partial, ",")
	default:
		return "complete", "ok"
	}
}

func (o *importOutcome) line() string {
	status, reason := o.status()
	o.mu.Lock()
	defer o.mu.Unlock()
	return fmt.Sprintf("%s status=%s reason=%s owner=%d tagged=%d relays=%d/%d other_vault=%s",
		importResultMarker, status, reason, o.owner, o.tagged, o.reached, o.seeds, o.otherVault)
}

// finishImport prints the result line once and stops collecting.
func (o *importOutcome) finish() {
	currentImport.CompareAndSwap(o, nil)
	l := o.line()
	lastImportResult.Store(l)
	log.Println("📋", l)
}

// observeImportLine feeds a log line to the import being collected, if any.
func observeImportLine(line string) {
	if o := currentImport.Load(); o != nil {
		o.observe(line)
	}
}

func importOtherVaultRelay() string {
	return strings.TrimSpace(os.Getenv(importOtherVaultEnv))
}
