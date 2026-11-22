package box

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// cmdEngine is fakeEngine that runs `sh -c script` for the engine's own
// commands, with the args in $@ and the vault folder as its directory.
type cmdEngine struct {
	*fakeEngine
	script string
	ran    []string
}

func (c *cmdEngine) Command(args ...string) *exec.Cmd {
	c.ran = append(c.ran, strings.Join(args, " "))
	cmd := exec.Command("sh", append([]string{"-c", c.script, "engine"}, args...)...)
	cmd.Dir = c.VaultDir()
	return cmd
}

// fakeEngineJobs answers box-jobs.json as the engine's box_jobs.go does,
// with the given codes, until the test ends.
func fakeEngineJobs(t *testing.T, dir string, codes map[string]int) {
	t.Helper()
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
			var asks map[string]map[string]any
			raw, err := os.ReadFile(filepath.Join(dir, "box-jobs.json"))
			if err != nil || json.Unmarshal(raw, &asks) != nil {
				continue
			}
			state := map[string]any{"trust": map[string]any{"running": true, "found": 9}}
			for area, ask := range asks {
				state[area] = map[string]any{"seq": ask["seq"], "code": codes[area]}
			}
			_ = writeJSONAtomic(filepath.Join(dir, "box-jobs-state.json"), state)
		}
	}()
}

func shortAsk(t *testing.T) {
	t.Helper()
	old := engineAskWait
	engineAskWait = 300 * time.Millisecond
	t.Cleanup(func() { engineAskWait = old })
}

func TestImportsReadsTheJobsFileAndStillToBringIn(t *testing.T) {
	srv, owner, member, api := signedInAPI(t)
	if st, out := call(t, srv, &member, "GET", "/api/box/imports", nil); st != 200 || len(out["jobs"].([]any)) != 0 {
		t.Fatalf("no file yet: %d %v", st, out)
	}
	os.WriteFile(filepath.Join(api.Mover.Engine.VaultDir(), "import_jobs.json"), []byte(`{"version":1,"jobs":[{"name":"replies","status":"partial","stored":12,"unread":[{"relay":"wss://r.example","from":1,"to":2,"why":"timeout"}]}]}`), 0o600)
	st, out := call(t, srv, &owner, "GET", "/api/box/imports", nil)
	job := out["jobs"].([]any)[0].(map[string]any)
	if st != 200 || job["name"] != "replies" || len(job["unread"].([]any)) != 1 {
		t.Fatalf("jobs: %d %v", st, out)
	}
}

func TestImportsRunAndCancelAskTheEngine(t *testing.T) {
	shortAsk(t)
	srv, _, member, api := signedInAPI(t)
	dir := api.Mover.Engine.VaultDir()
	// Nobody answers: asked, left for the engine.
	st, out := call(t, srv, &member, "POST", "/api/box/imports/run", jsonBody(map[string]string{"job": "replies"}))
	if st != 200 || out["asked"] != true || out["answered"] != false {
		t.Fatalf("unanswered: %d %v", st, out)
	}
	fakeEngineJobs(t, dir, map[string]int{"import": 2})
	st, out = call(t, srv, &member, "POST", "/api/box/imports/cancel", jsonBody(map[string]string{"job": "older_relays"}))
	if st != 200 || out["answered"] != true || out["code"].(float64) != 2 {
		t.Fatalf("answered: %d %v", st, out)
	}
	var asks map[string]map[string]any
	raw, _ := os.ReadFile(filepath.Join(dir, "box-jobs.json"))
	json.Unmarshal(raw, &asks)
	if asks["import"]["seq"].(float64) != 2 || asks["import"]["action"] != "cancel" || asks["import"]["job"] != "older_relays" {
		t.Fatalf("asks %v", asks)
	}
	if st, _ := call(t, srv, &member, "POST", "/api/box/imports/run", jsonBody(map[string]string{"job": "rm -rf"})); st != 400 {
		t.Fatalf("unknown job: %d", st)
	}
}

// One area's ask never drops another's.
func TestAskEngineKeepsOtherAreas(t *testing.T) {
	shortAsk(t)
	dir := t.TempDir()
	askEngine(dir, "wot", nil)
	askEngine(dir, "import", map[string]any{"action": "run", "job": "setup"})
	askEngine(dir, "wot", nil)
	var asks map[string]map[string]any
	raw, _ := os.ReadFile(filepath.Join(dir, "box-jobs.json"))
	json.Unmarshal(raw, &asks)
	if asks["wot"]["seq"].(float64) != 2 || asks["import"]["seq"].(float64) != 1 {
		t.Fatalf("asks %v", asks)
	}
}
