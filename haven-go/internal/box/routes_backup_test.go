package box

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// backupAPI: signedInAPI whose engine runs script for backup/restore.
func backupAPI(t *testing.T, script string) (srv *httptest.Server, owner, member testKey, api *API, eng *cmdEngine) {
	t.Helper()
	s, o, m, a := signedInAPI(t)
	eng = &cmdEngine{fakeEngine: a.Mover.Engine.(*fakeEngine), script: script}
	a.Mover.Engine = eng
	engineJobs.mu.Lock()
	engineJobs.last = nil
	engineJobs.mu.Unlock()
	return s, o, m, a, eng
}

func waitJob(t *testing.T) *EngineJob {
	t.Helper()
	for until := time.Now().Add(3 * time.Second); time.Now().Before(until); time.Sleep(10 * time.Millisecond) {
		if j := lastEngineJob(); j != nil && (j.Phase == "done" || j.Phase == "failed") {
			return j
		}
	}
	t.Fatalf("job still %+v", lastEngineJob())
	return nil
}

// A backup stops the engine, runs its backup into NV_DATA_DIR/backups, and
// starts it again; the list shows it.
func TestBackupNowStopsRunsStarts(t *testing.T) {
	srv, owner, member, api, eng := backupAPI(t, `[ "$1" = backup ] && printf zipped > "$3"`)
	if st, _ := call(t, srv, &member, "POST", "/api/box/backups/now", nil); st != 403 {
		t.Fatalf("member backed up: %d", st)
	}
	st, out := call(t, srv, &owner, "POST", "/api/box/backups/now", nil)
	if st != 202 || out["kind"] != "backup" {
		t.Fatalf("backup: %d %v", st, out)
	}
	if j := waitJob(t); j.Phase != "done" {
		t.Fatalf("job %+v", j)
	}
	eng.mu.Lock()
	log := strings.Join(eng.log, ",")
	eng.mu.Unlock()
	if !strings.HasPrefix(log, "stop,start ") || len(eng.ran) != 1 || !strings.HasPrefix(eng.ran[0], "backup -o "+api.Mover.backupsDir()) {
		t.Fatalf("engine log %q ran %v", log, eng.ran)
	}
	st, out = call(t, srv, &owner, "GET", "/api/box/backups", nil)
	list := out["backups"].([]any)
	if st != 200 || len(list) != 1 || out["job"].(map[string]any)["phase"] != "done" {
		t.Fatalf("list: %d %v", st, out)
	}
}

// A failed backup leaves no file and still starts the engine again.
func TestBackupFailureStartsTheEngineAgain(t *testing.T) {
	srv, owner, _, api, eng := backupAPI(t, `exit 3`)
	call(t, srv, &owner, "POST", "/api/box/backups/now", nil)
	if j := waitJob(t); j.Phase != "failed" || !strings.Contains(j.Error, "didn't finish") {
		t.Fatalf("job %+v", j)
	}
	dir := api.Mover.Engine.VaultDir()
	eng.mu.Lock()
	defer eng.mu.Unlock()
	if eng.log[len(eng.log)-1] != "start "+dir {
		t.Fatalf("engine not started again: %v", eng.log)
	}
	if n := len(api.Mover.Backups()); n != 0 {
		t.Fatalf("%d backups after a failure", n)
	}
}

func TestBackupsKeepTheNewest(t *testing.T) {
	_, _, _, api, _ := backupAPI(t, `true`)
	dir := api.Mover.backupsDir()
	os.MkdirAll(dir, 0o700)
	for i := 1; i <= backupsKept+2; i++ {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("vault-2026110%d-000000.zip", i)), []byte("z"), 0o600)
	}
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("mine"), 0o600)
	api.Mover.pruneBackups()
	got := api.Mover.Backups()
	if len(got) != backupsKept || got[0].Name != "vault-20261107-000000.zip" {
		t.Fatalf("kept %+v", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "notes.txt")); err != nil {
		t.Fatal("a file that isn't a backup was removed")
	}
}

// Restore takes only this box's backups by name, never a path.
func TestRestoreOnlyNamedBackups(t *testing.T) {
	srv, owner, _, api, eng := backupAPI(t, `[ "$1" = restore ] && [ -s "$3" ]`)
	for _, bad := range []string{"../../etc/passwd", "/tmp/x.zip", "vault-20261101-000000.zip"} {
		if st, _ := call(t, srv, &owner, "POST", "/api/box/backups/restore", jsonBody(map[string]string{"name": bad})); st != 400 {
			t.Errorf("%q: %d, want 400", bad, st)
		}
	}
	time.Sleep(1100 * time.Millisecond) // the same request again would be the same NIP-98 event, which the box refuses
	os.MkdirAll(api.Mover.backupsDir(), 0o700)
	os.WriteFile(filepath.Join(api.Mover.backupsDir(), "vault-20261101-000000.zip"), []byte("z"), 0o600)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/backups/restore", jsonBody(map[string]string{"name": "vault-20261101-000000.zip"})); st != 202 {
		t.Fatalf("restore: %d", st)
	}
	if j := waitJob(t); j.Phase != "done" || j.Kind != "restore" {
		t.Fatalf("job %+v", j)
	}
	if len(eng.ran) != 1 || eng.ran[0] != "restore -i "+filepath.Join(api.Mover.backupsDir(), "vault-20261101-000000.zip") {
		t.Fatalf("ran %v", eng.ran)
	}
}

// One engine job at a time, and none during a move; restart is first account only.
func TestEngineJobsOneAtATime(t *testing.T) {
	srv, owner, member, api, _ := backupAPI(t, `sleep 0.3`)
	if st, _ := call(t, srv, &member, "POST", "/api/box/restart", nil); st != 403 {
		t.Fatalf("member restarted: %d", st)
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/backups/now", nil); st != 202 {
		t.Fatalf("backup: %d", st)
	}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/restart", nil); st != 409 {
		t.Fatalf("restart during a backup: %d, want 409", st)
	}
	waitJob(t)
	time.Sleep(1100 * time.Millisecond) // a new NIP-98 event, not the refused one again
	if st, out := call(t, srv, &owner, "POST", "/api/box/restart", nil); st != 202 || out["kind"] != "restart" {
		t.Fatalf("restart: %d %v", st, out)
	}
	waitJob(t)
	api.Mover.mu.Lock()
	api.Mover.busy = true // a move
	api.Mover.mu.Unlock()
	time.Sleep(1100 * time.Millisecond)
	if st, _ := call(t, srv, &owner, "POST", "/api/box/backups/now", nil); st != 409 {
		t.Fatalf("backup during a move: %d, want 409", st)
	}
}
