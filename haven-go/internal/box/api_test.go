package box

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type stateOnly struct{ s EngineState }

func (e stateOnly) State() EngineState { return e.s }

func newTestAPI(t *testing.T) (*httptest.Server, testKey, *API) {
	owner := newTestKey(t)
	base := t.TempDir()
	vault := filepath.Join(base, "vault")
	makeVault(t, vault)
	os.MkdirAll(filepath.Join(base, "mnt", "usb"), 0o755)
	key, err := LoadOrCreateDeviceKey(filepath.Join(base, "box"))
	if err != nil {
		t.Fatal(err)
	}
	mesh := filepath.Join(base, "mesh.json")
	os.WriteFile(mesh, []byte(`{"up":true,"peers":2}`), 0o600)
	eng := &fakeEngine{dir: vault}
	api := &API{
		Auth: NewOwnerAuth(owner.pk), Version: "test-1", Started: time.Now().Add(-time.Minute),
		Key: key, Owner: "npub-owner", Engine: stateOnly{EngineState{Running: true, VaultDir: vault}},
		MeshStatus: mesh, Storage: &StorageMeter{},
		Devices: &Devices{OwnerHex: owner.pk, Key: key, Source: &fakeLists{}},
		Mover: &Mover{Root: filepath.Join(base, "mnt"), BoxDir: filepath.Join(base, "box"), Engine: eng,
			Ctx: context.Background(), FreeOf: func(string) (uint64, error) { return 1 << 30, nil }},
		Updater: &Updater{BoxDir: filepath.Join(base, "box")},
	}
	srv := httptest.NewServer(&Front{API: api, Engine: named("engine")})
	t.Cleanup(srv.Close)
	return srv, owner, api
}

func call(t *testing.T, srv *httptest.Server, k *testKey, method, path string, body []byte) (int, map[string]any) {
	t.Helper()
	if method != "POST" {
		body = nil
	}
	req, _ := http.NewRequest(method, srv.URL+path, bytes.NewReader(body))
	if k != nil {
		req.Header.Set("Authorization", k.authHeader(t, method, srv.URL+path, body, time.Now()))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func TestAPIOwnerOnlyOnEveryRoute(t *testing.T) {
	srv, _, _ := newTestAPI(t)
	stranger := newTestKey(t)
	for _, r := range []struct{ m, p string }{
		{"GET", "/api/box/status"}, {"GET", "/api/box/storage"}, {"GET", "/api/box/devices"},
		{"POST", "/api/box/update"}, {"POST", "/api/box/move"}, {"GET", "/api/box/nope"},
	} {
		if code, _ := call(t, srv, nil, r.m, r.p, []byte(`{}`)); code != 401 {
			t.Errorf("%s %s no auth: %d", r.m, r.p, code)
		}
		if code, _ := call(t, srv, &stranger, r.m, r.p, []byte(`{}`)); code != 403 {
			t.Errorf("%s %s stranger: %d", r.m, r.p, code)
		}
	}
}

func TestAPIStatusStorageDevices(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	code, st := call(t, srv, &owner, "GET", "/api/box/status", nil)
	if code != 200 {
		t.Fatalf("status %d %v", code, st)
	}
	for _, k := range []string{"version", "uptime", "mem", "disk", "mesh"} {
		if _, ok := st[k]; !ok {
			t.Errorf("status lacks %q: %v", k, st)
		}
	}
	if st["version"] != "test-1" || st["uptime"].(float64) < 59 || st["device"] != api.Key.Npub {
		t.Errorf("status %v", st)
	}
	if mesh := st["mesh"].(map[string]any); mesh["peers"] != float64(2) || mesh["up"] != true || mesh["npub"] != api.Key.Npub {
		t.Errorf("mesh %v", mesh)
	}
	if disk := st["disk"].(map[string]any); disk["total"].(float64) <= 0 {
		t.Errorf("disk %v", disk)
	}

	code, sto := call(t, srv, &owner, "GET", "/api/box/storage", nil)
	if code != 200 || sto["databaseBytes"].(float64) < 2*5000 || sto["blobCount"].(float64) != 1 || sto["blossomBytes"].(float64) < 4 || sto["otherBytes"].(float64) < 2 {
		t.Fatalf("storage %d %v", code, sto)
	}
	// The screens' storage shape (web-vault/src/box/api.js).
	if sto["path"] != api.Mover.Engine.VaultDir() || sto["total"].(float64) <= 0 || sto["free"].(float64) <= 0 || sto["used"].(float64) <= 0 {
		t.Fatalf("storage shape %v", sto)
	}

	code, dev := call(t, srv, &owner, "GET", "/api/box/devices", nil)
	box := dev["box"].(map[string]any)
	if code != 200 || box["npub"] != api.Key.Npub || box["approved"] != false || box["name"] == "" {
		t.Fatalf("devices %d %v", code, dev)
	}
}

func TestAPIMissingMeshStatus(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	api.MeshStatus = filepath.Join(t.TempDir(), "none.json")
	_, st := call(t, srv, &owner, "GET", "/api/box/status", nil)
	if m := st["mesh"].(map[string]any); m["up"] != false || m["npub"] != api.Key.Npub {
		t.Fatalf("mesh %v", m)
	}
}

func TestAPIUpdateWritesRequest(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	code, res := call(t, srv, &owner, "POST", "/api/box/update", nil)
	if code != 202 || res["via"] != "file" || res["started"] != true || res["from"] != "test-1" {
		t.Fatalf("update %d %v", code, res)
	}
	if _, err := os.Stat(filepath.Join(api.Updater.BoxDir, "update-request.json")); err != nil {
		t.Fatal(err)
	}
}

func TestAPIUpdateRunsHook(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	marker := filepath.Join(t.TempDir(), "ran")
	hook := filepath.Join(t.TempDir(), "hook.sh")
	os.WriteFile(hook, []byte("#!/bin/sh\necho \"$NV_UPDATE_REQUESTED_AT\" > "+marker+"\n"), 0o755)
	api.Updater.Hook = hook
	code, res := call(t, srv, &owner, "POST", "/api/box/update", nil)
	if code != 202 || res["via"] != "hook" {
		t.Fatalf("update %d %v", code, res)
	}
	waitFor(t, func() bool { b, _ := os.ReadFile(marker); return len(strings.TrimSpace(string(b))) > 0 })
}

func TestAPIMove(t *testing.T) {
	srv, owner, api := newTestAPI(t)
	if code, res := call(t, srv, &owner, "POST", "/api/box/move", []byte(`not json`)); code != 400 {
		t.Fatalf("bad body %d %v", code, res)
	}
	if code, res := call(t, srv, &owner, "POST", "/api/box/move", []byte(`{"path":"/etc"}`)); code != 400 {
		t.Fatalf("outside root %d %v", code, res)
	}
	target := filepath.Join(api.Mover.Root, "usb", "vault")
	code, res := call(t, srv, &owner, "POST", "/api/box/move", []byte(`{"path":"`+target+`"}`))
	if code != 202 || res["to"] != target || res["ok"] != true || res["path"] != target || !strings.Contains(res["message"].(string), target) {
		t.Fatalf("move %d %v", code, res)
	}
	if s := waitMove(t, api.Mover); s.Phase != "done" {
		t.Fatalf("move %+v", s)
	}
}
