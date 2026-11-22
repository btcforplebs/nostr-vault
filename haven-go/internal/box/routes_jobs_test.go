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
	fileEngineAsk(dir, "wot", nil)
	fileEngineAsk(dir, "import", map[string]any{"action": "run", "job": "setup"})
	fileEngineAsk(dir, "wot", nil)
	var asks map[string]map[string]any
	raw, _ := os.ReadFile(filepath.Join(dir, "box-jobs.json"))
	json.Unmarshal(raw, &asks)
	if asks["wot"]["seq"].(float64) != 2 || asks["import"]["seq"].(float64) != 1 {
		t.Fatalf("asks %v", asks)
	}
}

// A Move copies the vault folder: the four routes that write into it answer
// 409 and leave it alone until the Move ends (Tron's E5 review #1).
func TestEngineAsksWaitForAMove(t *testing.T) {
	shortAsk(t)
	srv, owner, member, api := signedInAPI(t)
	dir := api.Mover.Engine.VaultDir()
	api.Mover.mu.Lock()
	api.Mover.busy = true
	api.Mover.state = &MoveState{From: dir, Phase: "copying"}
	api.Mover.mu.Unlock()
	for _, c := range []struct {
		who  *testKey
		path string
		body any
	}{
		{&member, "/api/box/imports/run", map[string]string{"job": "replies"}},
		{&member, "/api/box/imports/cancel", map[string]string{"job": "replies"}},
		{&member, "/api/box/trust/refresh", nil},
		{&owner, "/api/box/blocklist", map[string][]string{"npubs": {}}},
	} {
		var body []byte
		if c.body != nil {
			body = jsonBody(c.body)
		}
		if st, out := call(t, srv, c.who, "POST", c.path, body); st != 409 {
			t.Fatalf("%s during a move: %d %v", c.path, st, out)
		}
	}
	for _, f := range []string{"box-jobs.json", "blacklisted_npubs.json"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
			t.Fatalf("%s written during a move", f)
		}
	}
	// The move ended: asks go through again.
	api.Mover.mu.Lock()
	api.Mover.state.Finished = time.Now().Unix()
	api.Mover.busy = false
	api.Mover.mu.Unlock()
	if st, out := call(t, srv, &owner, "POST", "/api/box/trust/refresh", nil); st != 200 {
		t.Fatalf("after the move: %d %v", st, out)
	}
	// A backup, restore or restart holds busy without a move: asks still go.
	api.Mover.mu.Lock()
	api.Mover.busy = true
	api.Mover.mu.Unlock()
	if st, out := call(t, srv, &member, "POST", "/api/box/imports/run", jsonBody(map[string]string{"job": "setup"})); st != 200 {
		t.Fatalf("during an engine job: %d %v", st, out)
	}
}
