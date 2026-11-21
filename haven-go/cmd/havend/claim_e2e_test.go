//go:build havend_e2e

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Claim mode end to end (Umbrel: no NV_OWNER, NV_SETUP_CODE set): until the
// right code arrives the box serves only the setup page, a visitor without
// the code can't claim it, and after the claim havend runs as the normal box
// for that owner, which a restart keeps (box/owner).
func TestClaimEndToEnd(t *testing.T) {
	dir := t.TempDir()
	havend, engine := filepath.Join(dir, "havend"), filepath.Join(dir, "haven-engine")
	build(t, havend, "-ldflags", "-X main.version=e2e", "./cmd/havend")
	build(t, engine, "-tags", "nolmdb", ".")

	owner, visitor := newKey(t), newKey(t)
	data := filepath.Join(dir, "data")
	vault := filepath.Join(data, "vault")
	os.MkdirAll(vault, 0o700)
	for _, f := range []string{"relays_import.json", "relays_blastr.json", "relays_dm.json"} {
		os.WriteFile(filepath.Join(vault, f), []byte("[]"), 0o600)
	}
	const code = "umbrel-app-password-0123456789abcdef"
	port, enginePort, doorPort := freePort(t), freePort(t), freePort(t)
	env := []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + dir,
		"NV_SETUP_CODE=" + code, "NV_DATA_DIR=" + data, "NV_PORT=" + strconv.Itoa(port),
		"NV_ENGINE_PORT=" + strconv.Itoa(enginePort), "NV_ENGINE_BIN=" + engine,
		"NV_DIRECTORY_RELAYS=ws://127.0.0.1:1", "NV_MESH_DOOR_PORT=" + strconv.Itoa(doorPort),
		"NV_UPDATE_VIA=umbrel", "NV_MOVE_ROOT=",
	}
	logPath := filepath.Join(dir, "havend.log")
	start := func() *exec.Cmd {
		cmd := exec.Command(havend)
		cmd.Env = env
		logf, _ := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		cmd.Stdout, cmd.Stderr = logf, logf
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		return cmd
	}
	cmd := start()
	defer func() {
		cmd.Process.Signal(os.Interrupt)
		cmd.Wait()
		if t.Failed() {
			b, _ := os.ReadFile(logPath)
			t.Logf("havend log:\n%s", b)
		}
	}()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	waitFor(t, func() bool {
		resp, err := http.Get(base + "/")
		if err != nil {
			return false
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp.StatusCode == 200 && bytes.Contains(b, []byte("Set up Nostr Vault"))
	})

	// Before the claim: no relay, no box API, no Blossom.
	for _, p := range []string{"/api/box/status", "/upload", "/" + strings.Repeat("a", 64)} {
		if resp, err := http.Get(base + p); err != nil {
			t.Fatal(err)
		} else if resp.Body.Close(); resp.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("claim mode GET %s = %d, want 503", p, resp.StatusCode)
		}
	}
	nip11, _ := http.NewRequest("GET", base+"/", nil)
	nip11.Header.Set("Accept", "application/nostr+json")
	if resp, err := http.DefaultClient.Do(nip11); err != nil {
		t.Fatal(err)
	} else {
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if bytes.Contains(b, []byte("Nostr Vault Public")) {
			t.Fatal("the vault engine answered before the box was claimed")
		}
	}

	post := func(npub, c string) int {
		resp, err := http.PostForm(base+"/setup", url.Values{"npub": {npub}, "code": {c}})
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	// The first visitor, without the code: refused, nothing saved.
	for _, c := range []string{"", "wrong", code[:len(code)-1], code + "x"} {
		if st := post(visitor.npub, c); st != http.StatusForbidden {
			t.Fatalf("visitor with code %q: %d, want 403", c, st)
		}
	}
	if _, err := os.Stat(filepath.Join(data, "box", "owner")); !os.IsNotExist(err) {
		t.Fatalf("box/owner after refused claims: %v", err)
	}
	// Five wrong codes in a minute: even the right one waits now.
	if st := post(owner.npub, "wrong"); st != http.StatusForbidden {
		t.Fatalf("fifth wrong code: %d", st)
	}
	if st := post(owner.npub, code); st != http.StatusTooManyRequests {
		t.Fatalf("after five wrong codes: %d, want 429", st)
	}
	cmd.Process.Signal(os.Interrupt) // a restart forgets the count; box/owner is still absent
	cmd.Wait()
	cmd = start()
	waitFor(t, func() bool {
		resp, err := http.Get(base + "/")
		if err == nil {
			resp.Body.Close()
		}
		return err == nil
	})

	if st := post(owner.npub, code); st != http.StatusOK {
		t.Fatalf("owner claim: %d, want 200", st)
	}
	saved, _ := os.ReadFile(filepath.Join(data, "box", "owner"))
	if strings.TrimSpace(string(saved)) != owner.npub {
		t.Fatalf("box/owner = %q, want %s", saved, owner.npub)
	}
	// Now the normal box: the engine answers, the setup page is gone, and
	// the box API is the owner's only.
	waitFor(t, func() bool {
		req, _ := http.NewRequest("GET", base+"/", nil)
		req.Header.Set("Accept", "application/nostr+json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return false
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return bytes.Contains(b, []byte("Nostr Vault Public"))
	})
	if resp, err := http.PostForm(base+"/setup", url.Values{"npub": {visitor.npub}, "code": {code}}); err == nil {
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			b, _ := os.ReadFile(filepath.Join(data, "box", "owner"))
			if strings.TrimSpace(string(b)) != owner.npub {
				t.Fatal("a second claim changed the owner")
			}
		}
	}
	if st, _ := boxCall(t, base, visitor, "GET", "/api/box/status", nil); st != http.StatusForbidden {
		t.Fatalf("visitor status = %d, want 403", st)
	}
	st, status := boxCall(t, base, owner, "GET", "/api/box/status", nil)
	if st != 200 || status["owner"] != owner.npub || status["update_via"] != "umbrel" || status["move_off"] != true {
		t.Fatalf("owner status = %d %v", st, status)
	}
	if st, up := boxCall(t, base, owner, "POST", "/api/box/update", []byte("{}")); st != 200 || up["managed"] != true || up["via"] != "umbrel" {
		t.Fatalf("update = %d %v", st, up)
	}
	if st, mv := boxCall(t, base, owner, "POST", "/api/box/move", []byte(`{"path":"/mnt/usb/nv"}`)); st != http.StatusForbidden {
		t.Fatalf("move with Move off = %d %v", st, mv)
	}

	// A restart reads box/owner: still the owner's box, no setup page.
	cmd.Process.Signal(os.Interrupt)
	cmd.Wait()
	cmd = start()
	waitFor(t, func() bool {
		st, s := boxCallNoFatal(base, owner, "GET", "/api/box/status")
		return st == 200 && s["owner"] == owner.npub
	})
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func boxCallNoFatal(base string, k key, method, path string) (int, map[string]any) {
	req, _ := http.NewRequest(method, base+path, nil)
	req.Header.Set("Authorization", k.nip98(method, base+path, nil))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = jsonDecode(resp.Body, &out)
	return resp.StatusCode, out
}

func jsonDecode(r io.Reader, v any) error { return json.NewDecoder(r).Decode(v) }
