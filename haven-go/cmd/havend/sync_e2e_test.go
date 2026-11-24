//go:build havend_e2e

// End-to-end run of the box catching up from another of the owner's vaults
// (One Vault spec E3): two boxes of one throwaway owner on loopback. Vault A
// holds a note and a file; box B pulls them with a first copy it starts with
// its own mesh key, then a second file with a catch-up. nv-mesh's dial.sock
// is played by the test (it hands B A's loopback port and signs the start
// with B's mesh key, as dial.rs does); everything else is the real havend
// and engine. Run with:
//
//	go test -tags havend_e2e -count=1 -run TestBoxSync -v ./cmd/havend/
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
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

type testBox struct {
	data, base string
	port       int
	cmd        *exec.Cmd
	log        string
}

func startBox(t *testing.T, root, name, havend, engine string, owner, mesh key, runDir string) *testBox {
	data := filepath.Join(root, name)
	vault := filepath.Join(data, "vault")
	os.MkdirAll(vault, 0o700)
	for _, f := range []string{"relays_import.json", "relays_blastr.json", "relays_dm.json"} {
		os.WriteFile(filepath.Join(vault, f), []byte("[]"), 0o600)
	}
	os.MkdirAll(filepath.Join(data, "mesh"), 0o755)
	os.WriteFile(filepath.Join(data, "mesh", "npub"), []byte(mesh.npub+"\n"), 0o644)
	port, enginePort, doorPort := freePort(t), freePort(t), freePort(t)
	b := &testBox{data: data, port: port, base: "http://127.0.0.1:" + strconv.Itoa(port), log: filepath.Join(root, name+".log")}
	b.cmd = exec.Command(havend)
	b.cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + root,
		"NV_OWNER=" + owner.npub, "NV_DATA_DIR=" + data, "NV_PORT=" + strconv.Itoa(port),
		"NV_ENGINE_PORT=" + strconv.Itoa(enginePort), "NV_ENGINE_BIN=" + engine,
		"NV_MOVE_ROOT=", "NV_DIRECTORY_RELAYS=ws://127.0.0.1:1",
		"NV_MESH_DOOR_PORT=" + strconv.Itoa(doorPort), "NV_MESH_RUN_DIR=" + runDir,
		"NV_BOX_RUN_DIR=" + filepath.Join(root, name+"-run"),
	}
	logf, _ := os.Create(b.log)
	b.cmd.Stdout, b.cmd.Stderr = logf, logf
	if err := b.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		b.cmd.Process.Signal(os.Interrupt)
		b.cmd.Wait()
		if t.Failed() {
			l, _ := os.ReadFile(b.log)
			t.Logf("%s log:\n%s", name, l)
		}
	})
	deadline := time.Now().Add(60 * time.Second)
	for {
		req, _ := http.NewRequest("GET", b.base+"/", nil)
		req.Header.Set("Accept", "application/nostr+json")
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: engine never answered", name)
		}
		time.Sleep(300 * time.Millisecond)
	}
	return b
}

func (b *testBox) publish(t *testing.T, ctx context.Context, evs ...nostr.Event) {
	r, err := nostr.RelayConnect(ctx, "ws://127.0.0.1:"+strconv.Itoa(b.port))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	for _, ev := range evs {
		if err := r.Publish(ctx, ev); err != nil {
			t.Fatalf("publish kind %d: %v", ev.Kind, err)
		}
	}
}

func (b *testBox) has(t *testing.T, ctx context.Context, id string) bool {
	r, err := nostr.RelayConnect(ctx, "ws://127.0.0.1:"+strconv.Itoa(b.port))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	got, _ := r.QuerySync(ctx, nostr.Filter{IDs: []string{id}})
	return len(got) == 1
}

func (b *testBox) upload(t *testing.T, owner key, blob []byte) string {
	sum := sha256.Sum256(blob)
	hash := hex.EncodeToString(sum[:])
	auth := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: "upload", Tags: nostr.Tags{
		{"t", "upload"}, {"x", hash}, {"expiration", strconv.FormatInt(time.Now().Add(5*time.Minute).Unix(), 10)},
	}}
	auth.Sign(owner.sk)
	ab, _ := json.Marshal(auth)
	req, _ := http.NewRequest("PUT", b.base+"/upload", bytes.NewReader(blob))
	req.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(ab))
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rb, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		t.Fatalf("upload %d %s", resp.StatusCode, rb)
	}
	return hash
}

func (b *testBox) blob(hash string) []byte {
	resp, err := http.Get(b.base + "/" + hash)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil
	}
	got, _ := io.ReadAll(resp.Body)
	return got
}

// fakeDial plays nv-mesh's dial.sock for box B: only vault A is one of the
// owner's devices; dial gives A's loopback port, and sign_copy_start signs
// with B's mesh key, as dial.rs builds it (u, method, p).
func fakeDial(t *testing.T, sock string, boxMesh key, aNpub, aBase string) {
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				line, _ := bufio.NewReader(c).ReadBytes('\n')
				var req map[string]string
				json.Unmarshal(line, &req)
				out := map[string]any{"ok": false, "error": "not one of the owner's devices on this box's mesh"}
				if req["npub"] == aNpub {
					switch req["op"] {
					case "dial":
						out = map[string]any{"ok": true, "base": aBase}
					case "sign_copy_start":
						u := strings.TrimSuffix(req["base"], "/") + "/copy/v2/start"
						ev := nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"u", u}, {"method", "POST"}, {"p", aNpub}}}
						ev.Sign(boxMesh.sk)
						raw, _ := json.Marshal(ev)
						out = map[string]any{"ok": true, "auth": base64.StdEncoding.EncodeToString(raw)}
					}
				}
				raw, _ := json.Marshal(out)
				c.Write(append(raw, '\n'))
			}(c)
		}
	}()
}

// call is boxCall with a nonce tag: this test asks more than once a second,
// and two equal proofs are one replayed proof to the box.
func call(t *testing.T, base string, k key, method, path string, body []byte) (int, map[string]any) {
	tags := nostr.Tags{{"u", base + path}, {"method", method}, {"nonce", strconv.FormatInt(time.Now().UnixNano(), 10)}}
	if len(body) > 0 {
		s := sha256.Sum256(body)
		tags = append(tags, nostr.Tag{"payload", hex.EncodeToString(s[:])})
	}
	ev := nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: tags}
	ev.Sign(k.sk)
	raw, _ := json.Marshal(ev)
	req, _ := http.NewRequest(method, base+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(raw))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func syncDevice(t *testing.T, b *testBox, owner key, npub string) map[string]any {
	code, rep := call(t, b.base, owner, "GET", "/api/box/sync", nil)
	if code != 200 {
		t.Fatalf("GET sync %d %v", code, rep)
	}
	devs, _ := rep["devices"].([]any)
	for _, d := range devs {
		if m := d.(map[string]any); m["peer"] == npub {
			return m
		}
	}
	return nil
}

// waitRun waits for the device's last run of kind to finish, and returns it.
func waitRun(t *testing.T, b *testBox, owner key, npub, kind string, after int64) map[string]any {
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		if d := syncDevice(t, b, owner, npub); d != nil {
			if last, ok := d["last"].(map[string]any); ok && last["kind"] == kind && last["finished"] != nil && int64(last["started"].(float64)) >= after {
				return d
			}
		}
		time.Sleep(time.Second)
	}
	t.Fatalf("no finished %s run with %s", kind, npub)
	return nil
}

func TestBoxSyncEndToEnd(t *testing.T) {
	// Short paths: unix sockets are capped near 104 bytes on macOS.
	root, err := os.MkdirTemp("/tmp", "nvs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	havend, engine := filepath.Join(root, "havend"), filepath.Join(root, "haven-engine")
	build(t, havend, "-ldflags", "-X main.version=e2e", "./cmd/havend")
	build(t, engine, "-tags", "nolmdb", ".")

	owner, aMesh, bMesh := newKey(t), newKey(t), newKey(t)
	runB := filepath.Join(root, "runb")
	os.MkdirAll(runB, 0o750)
	a := startBox(t, root, "a", havend, engine, owner, aMesh, filepath.Join(root, "runa"))
	fakeDial(t, filepath.Join(runB, "dial.sock"), bMesh, aMesh.npub, a.base)
	b := startBox(t, root, "b", havend, engine, owner, bMesh, runB)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// The owner's devices: both vaults, in the 10063 both hold.
	list := nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"server", "fipsmesh://" + aMesh.npub + "/"}, {"server", "fipsmesh://" + bMesh.npub + "/"},
	}}
	list.Sign(owner.sk)
	a.publish(t, ctx, list)
	b.publish(t, ctx, list)

	// What A holds: a note and a file.
	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "made on vault A " + strconv.FormatInt(time.Now().UnixNano(), 10)}
	note.Sign(owner.sk)
	a.publish(t, ctx, note)
	file1 := []byte("vault A's first file " + note.ID)
	hash1 := a.upload(t, owner, file1)
	if b.blob(hash1) != nil || b.has(t, ctx, note.ID) {
		t.Fatal("B holds A's note or file before any copy")
	}

	// Both boxes read the 10063 (every 30 s) and the engines take the
	// paired set (every 5 s): wait until B offers A for a first copy.
	deadline := time.Now().Add(90 * time.Second)
	var dev map[string]any
	for {
		if dev = syncDevice(t, b, owner, aMesh.npub); dev != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("B never listed A as a paired device")
		}
		time.Sleep(2 * time.Second)
	}
	if dev["needs"] != "first_copy" || dev["token"] != false {
		t.Fatalf("before a first copy: %v", dev)
	}
	// A stranger's device is refused.
	stranger := newKey(t)
	if code, _ := call(t, b.base, owner, "POST", "/api/box/sync/first", []byte(`{"device":"`+stranger.npub+`"}`)); code != 404 {
		t.Fatalf("first copy from a stranger: %d, want 404", code)
	}
	// A's engine may take a few seconds more to read B into its paired set.
	time.Sleep(6 * time.Second)

	started := time.Now().Unix()
	if code, out := call(t, b.base, owner, "POST", "/api/box/sync/first", []byte(`{"device":"`+aMesh.npub+`"}`)); code != 202 {
		t.Fatalf("first copy %d %v", code, out)
	}
	dev = waitRun(t, b, owner, aMesh.npub, "first", started)
	if last := dev["last"].(map[string]any); last["error"] != nil || dev["token"] != true {
		t.Fatalf("first copy: %v", dev)
	}
	if got := b.blob(hash1); !bytes.Equal(got, file1) {
		t.Fatalf("A's file not on B after the first copy: %q", got)
	}
	if !b.has(t, ctx, note.ID) {
		t.Fatal("A's note not on B after the first copy")
	}
	// A issued the token to B's mesh key, never to an account key.
	raw, _ := os.ReadFile(filepath.Join(a.data, "vault", "copy_tokens.json"))
	var toks []struct{ Device string }
	json.Unmarshal(raw, &toks)
	if len(toks) != 1 || toks[0].Device != bMesh.pk {
		t.Fatalf("A's copy tokens %s, want one for B's mesh key %s", raw, bMesh.pk)
	}

	// A new file on A arrives with a catch-up (Sync now).
	file2 := []byte("vault A's second file " + strconv.FormatInt(time.Now().UnixNano(), 10))
	hash2 := a.upload(t, owner, file2)
	started = time.Now().Unix()
	if code, out := call(t, b.base, owner, "POST", "/api/box/sync/now", []byte(`{"device":"`+aMesh.npub+`"}`)); code != 202 {
		t.Fatalf("sync now %d %v", code, out)
	}
	// Asked again at once: throttled (one Sync now per device per minute).
	if code, out := call(t, b.base, owner, "POST", "/api/box/sync/now", []byte(`{"device":"`+aMesh.npub+`"}`)); code != 429 || out["retryAfter"] == nil {
		t.Fatalf("second sync now %d %v, want 429 with retryAfter", code, out)
	}
	dev = waitRun(t, b, owner, aMesh.npub, "sync", started)
	if last := dev["last"].(map[string]any); last["error"] != nil || last["files"] == nil {
		t.Fatalf("catch-up: %v", dev)
	}
	if got := b.blob(hash2); !bytes.Equal(got, file2) {
		t.Fatalf("A's second file not on B after the catch-up: %q", got)
	}
	t.Logf("B after the catch-up: %v", dev)
}
