//go:build havend_e2e

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The box's added accounts with the real engine: box/accounts.json gives a
// watch-only account vault space but no private reads, a signed-in one
// private reads, and editing the file reaches the engine by itself.
func TestBoxAccountsEndToEnd(t *testing.T) {
	dir := t.TempDir()
	havend, engine := filepath.Join(dir, "havend"), filepath.Join(dir, "haven-engine")
	build(t, havend, "./cmd/havend")
	build(t, engine, "-tags", "nolmdb", ".")

	owner, watch, signed, stranger := newKey(t), newKey(t), newKey(t), newKey(t)
	data := filepath.Join(dir, "data")
	vault := filepath.Join(data, "vault")
	os.MkdirAll(vault, 0o700)
	for _, f := range []string{"relays_import.json", "relays_blastr.json", "relays_dm.json"} {
		os.WriteFile(filepath.Join(vault, f), []byte("[]"), 0o600)
	}
	writeAccounts := func(watchSigned bool) {
		b, _ := json.Marshal([]map[string]any{
			{"npub": watch.npub, "added": 1, "signedIn": watchSigned},
			{"npub": signed.npub, "added": 1, "signedIn": true},
		})
		os.MkdirAll(filepath.Join(data, "box"), 0o700)
		if err := os.WriteFile(filepath.Join(data, "box", "accounts.json"), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeAccounts(false)

	port, enginePort, doorPort := freePort(t), freePort(t), freePort(t)
	cmd := exec.Command(havend)
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + dir,
		"NV_OWNER=" + owner.npub, "NV_DATA_DIR=" + data, "NV_PORT=" + strconv.Itoa(port),
		"NV_ENGINE_PORT=" + strconv.Itoa(enginePort), "NV_ENGINE_BIN=" + engine,
		"NV_MOVE_ROOT=", "NV_DIRECTORY_RELAYS=ws://127.0.0.1:1",
		"NV_MESH_DOOR_PORT=" + strconv.Itoa(doorPort),
	}
	logPath := filepath.Join(dir, "havend.log")
	logf, _ := os.Create(logPath)
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cmd.Process.Signal(os.Interrupt)
		cmd.Wait()
		if t.Failed() {
			b, _ := os.ReadFile(logPath)
			t.Logf("havend log:\n%s", b)
		}
	}()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	engineUp := func() {
		t.Helper()
		deadline := time.Now().Add(60 * time.Second)
		for {
			req, _ := http.NewRequest("GET", base+"/", nil)
			req.Header.Set("Accept", "application/nostr+json")
			if resp, err := http.DefaultClient.Do(req); err == nil {
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				if resp.StatusCode == 200 && bytes.Contains(b, []byte("Nostr Vault Public")) {
					return
				}
			}
			if time.Now().After(deadline) {
				t.Fatal("engine never answered NIP-11 through the front door")
			}
			time.Sleep(300 * time.Millisecond)
		}
	}
	engineUp()

	// postPrivate: k AUTHs at /private and publishes its own note there.
	// Only a private reader may (MustBePrivateReaderToPost).
	postPrivate := func(k key) error {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		r, err := nostr.RelayConnect(ctx, "ws://127.0.0.1:"+strconv.Itoa(port)+"/private")
		if err != nil {
			return err
		}
		defer r.Close()
		time.Sleep(500 * time.Millisecond) // the challenge arrives on connect
		if err := r.Auth(ctx, func(e *nostr.Event) error { return e.Sign(k.sk) }); err != nil {
			return err
		}
		ev := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "private from " + k.npub[:12]}
		ev.Sign(k.sk)
		return r.Publish(ctx, ev)
	}
	mustPost := func(who string, k key) {
		t.Helper()
		if err := postPrivate(k); err != nil {
			t.Fatalf("%s: private post refused: %v", who, err)
		}
	}
	mustRefuse := func(who string, k key) {
		t.Helper()
		if err := postPrivate(k); err == nil {
			t.Fatalf("%s: private post accepted, want refused", who)
		}
	}

	// readPrivate: how many notes k gets back from a REQ at /private after
	// AUTH. A refused REQ (CLOSED, or no answer) counts as none.
	readPrivate := func(k key) int {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		r, err := nostr.RelayConnect(ctx, "ws://127.0.0.1:"+strconv.Itoa(port)+"/private")
		if err != nil {
			return 0
		}
		defer r.Close()
		time.Sleep(500 * time.Millisecond)
		if err := r.Auth(ctx, func(e *nostr.Event) error { return e.Sign(k.sk) }); err != nil {
			return 0
		}
		evs, err := r.QuerySync(ctx, nostr.Filter{Kinds: []int{1}, Limit: 50})
		if err != nil {
			return 0
		}
		return len(evs)
	}

	mustPost("first account", owner)
	mustPost("signed-in added account", signed)
	mustRefuse("watch-only added account", watch)
	mustRefuse("stranger", stranger)

	// Reads (Tron #2375): the readers see the private notes; a watch-only
	// account and a stranger get none. The owner's count is the control that
	// this REQ can return notes at all.
	if n := readPrivate(owner); n < 2 {
		t.Fatalf("first account read %d private notes, want 2+", n)
	}
	if n := readPrivate(signed); n < 2 {
		t.Fatalf("signed-in account read %d private notes, want 2+", n)
	}
	if n := readPrivate(watch); n != 0 {
		t.Fatalf("watch-only added account read %d private notes, want 0", n)
	}
	if n := readPrivate(stranger); n != 0 {
		t.Fatalf("stranger read %d private notes, want 0", n)
	}

	// Both lists are on disk, the readers list named and short.
	var readers []string
	b, _ := os.ReadFile(filepath.Join(vault, "private_reader_npubs.json"))
	json.Unmarshal(b, &readers)
	if strings.Join(readers, ",") != owner.npub+","+signed.npub {
		t.Fatalf("private_reader_npubs.json = %v", readers)
	}

	// The watch-only account signs in: the file alone reaches the engine.
	writeAccounts(true)
	deadline := time.Now().Add(30 * time.Second)
	for {
		lb, _ := os.ReadFile(logPath)
		if strings.Contains(string(lb), "accounts changed (3 accounts, 3 private readers)") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("havend never noticed accounts.json changed")
		}
		time.Sleep(200 * time.Millisecond)
	}
	time.Sleep(500 * time.Millisecond) // the old engine is stopping
	engineUp()
	mustPost("watch-only account after signing in", watch)

	// Removed: gone from both lists after the next restart; refused again.
	os.WriteFile(filepath.Join(data, "box", "accounts.json"), []byte("[]"), 0o600)
	deadline = time.Now().Add(30 * time.Second)
	for {
		lb, _ := os.ReadFile(logPath)
		if strings.Contains(string(lb), "accounts changed (1 accounts, 1 private readers)") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("havend never noticed the accounts were removed")
		}
		time.Sleep(200 * time.Millisecond)
	}
	time.Sleep(500 * time.Millisecond)
	engineUp()
	mustRefuse("removed account", watch)
	mustPost("first account after removals", owner)

	// Through the box API: the first account makes a code, a new account
	// joins with its own signature, and the engine reloads at once (no 5 s
	// wait for the file check) so it reads the private side.
	joiner := newKey(t)
	mustRefuse("joiner before joining", joiner)
	st, out := boxCall(t, base, owner, "POST", "/api/box/accounts/code", nil)
	code, _ := out["code"].(string)
	if st != 200 || code == "" {
		t.Fatalf("code: %d %v", st, out)
	}
	jb, _ := json.Marshal(map[string]string{"code": code})
	if st, out := boxCall(t, base, joiner, "POST", "/api/box/accounts/join", jb); st != 200 || out["state"] != "signedIn" {
		t.Fatalf("join: %d %v", st, out)
	}
	deadline = time.Now().Add(30 * time.Second)
	for {
		lb, _ := os.ReadFile(logPath)
		if strings.Contains(string(lb), "accounts changed (2 accounts, 2 private readers)") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the join never reloaded the engine")
		}
		time.Sleep(200 * time.Millisecond)
	}
	time.Sleep(500 * time.Millisecond)
	engineUp()
	mustPost("joined account", joiner)
	// The same code again, by someone else: spent.
	if st, _ := boxCall(t, base, stranger, "POST", "/api/box/accounts/join", jb); st != 403 {
		t.Fatalf("code reused: %d, want 403", st)
	}
	// A joined account is no first account: box controls stay closed.
	if st, _ := boxCall(t, base, joiner, "GET", "/api/box/status", nil); st != 403 {
		t.Fatalf("joined account status: %d, want 403", st)
	}
}
