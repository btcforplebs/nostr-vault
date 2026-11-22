//go:build !cshared && !(js && wasm)

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/barrydeen/haven/pkg/wot"
)

type boxJobsCalls struct{ runs, cancels, refreshes, blocklists []string }

func newTestBoxJobs(t *testing.T, dir string, calls *boxJobsCalls) *boxJobs {
	t.Helper()
	b := &boxJobs{
		dir:       dir,
		run:       func(n string) int { calls.runs = append(calls.runs, n); return 0 },
		cancel:    func(n string) int { calls.cancels = append(calls.cancels, n); return 1 },
		refresh:   func() bool { calls.refreshes = append(calls.refreshes, "x"); return true },
		blocklist: func() int { calls.blocklists = append(calls.blocklists, "x"); return 2 },
		progress:  func() wot.Progress { return wot.Progress{Running: true, Found: 7} },
	}
	b.loadState()
	return b
}

func writeAsks(t *testing.T, dir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, boxJobsFile), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readBoxState(t *testing.T, dir string) boxJobsState {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, boxJobsStateFile))
	if err != nil {
		t.Fatal(err)
	}
	var s boxJobsState
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// No box-jobs.json: nothing runs and nothing is written (an engine without havend).
func TestBoxJobsNothingWithoutTheFile(t *testing.T) {
	dir, calls := t.TempDir(), &boxJobsCalls{}
	if newTestBoxJobs(t, dir, calls).tick() {
		t.Fatal("tick acted with no box-jobs.json")
	}
	if _, err := os.Stat(filepath.Join(dir, boxJobsStateFile)); !os.IsNotExist(err) {
		t.Fatalf("state written: %v", err)
	}
}

// Each area runs once per new seq, and its answer lands in the state file.
func TestBoxJobsRunEachSeqOnce(t *testing.T) {
	dir, calls := t.TempDir(), &boxJobsCalls{}
	b := newTestBoxJobs(t, dir, calls)
	writeAsks(t, dir, `{"import":{"seq":1,"action":"run","job":"replies"},"wot":{"seq":1},"blocklist":{"seq":4}}`)
	b.tick()
	b.tick()
	if len(calls.runs) != 1 || calls.runs[0] != "replies" || len(calls.refreshes) != 1 || len(calls.blocklists) != 1 {
		t.Fatalf("calls %+v", calls)
	}
	s := readBoxState(t, dir)
	if s.Import.Seq != 1 || s.Import.Code != 0 || s.Wot.Seq != 1 || s.Blocklist.Seq != 4 || s.Blocklist.Code != 2 || s.Trust.Found != 7 {
		t.Fatalf("state %+v", s)
	}
	writeAsks(t, dir, `{"import":{"seq":2,"action":"cancel","job":"replies"},"wot":{"seq":1},"blocklist":{"seq":4}}`)
	b.tick()
	if len(calls.cancels) != 1 || len(calls.runs) != 1 || len(calls.refreshes) != 1 {
		t.Fatalf("second round %+v", calls)
	}
	if s := readBoxState(t, dir); s.Import.Seq != 2 || s.Import.Code != 1 {
		t.Fatalf("cancel state %+v", s.Import)
	}
}

// A restarted engine reads the seqs it did and repeats none of them, but
// still does one written while it was down.
func TestBoxJobsRestartRepeatsNothing(t *testing.T) {
	dir, calls := t.TempDir(), &boxJobsCalls{}
	writeAsks(t, dir, `{"import":{"seq":1,"action":"run","job":"setup"}}`)
	newTestBoxJobs(t, dir, calls).tick()
	writeAsks(t, dir, `{"import":{"seq":1,"action":"run","job":"setup"},"wot":{"seq":1}}`) // asked while down
	again := &boxJobsCalls{}
	newTestBoxJobs(t, dir, again).tick()
	if len(again.runs) != 0 || len(again.refreshes) != 1 {
		t.Fatalf("after restart %+v", again)
	}
}

// An unknown action answers 1 and runs nothing; a file that does not parse does nothing.
func TestBoxJobsRefusals(t *testing.T) {
	dir, calls := t.TempDir(), &boxJobsCalls{}
	b := newTestBoxJobs(t, dir, calls)
	writeAsks(t, dir, `{"import":{"seq":1,"action":"wipe","job":"setup"}}`)
	b.tick()
	if len(calls.runs)+len(calls.cancels) != 0 || readBoxState(t, dir).Import.Code != 1 {
		t.Fatalf("unknown action ran: %+v", calls)
	}
	writeAsks(t, dir, `{not json`)
	if !b.tick() || len(calls.runs) != 0 {
		t.Fatal("a bad file must do nothing")
	}
}

// The block list is read again from BLACKLISTED_NPUBS_FILE into the live list.
func TestReloadBlocklist(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "blacklisted_npubs.json")
	os.WriteFile(path, []byte(`["npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"]`), 0o600)
	t.Setenv("BLACKLISTED_NPUBS_FILE", path)
	t.Cleanup(func() { UpdateBlacklist(map[string]struct{}{}) })
	if n := reloadBlocklist(); n != 1 {
		t.Fatalf("blocked %d, want 1", n)
	}
	if !isBlacklisted("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d") {
		t.Fatal("the reloaded key is not blocked")
	}
}
