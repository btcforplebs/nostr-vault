//go:build havend_e2e

// End-to-end run of the box with a throwaway owner key: builds havend and
// the vault engine, starts them on spare ports with no outside relays, and
// drives the relay, Blossom, the web app and every box API route through
// the one front port. Run with:
//
//	go test -tags havend_e2e -count=1 -v ./cmd/havend/
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
	"github.com/nbd-wtf/go-nostr/nip19"
)

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func build(t *testing.T, out string, args ...string) {
	cmd := exec.Command("go", append([]string{"build", "-o", out}, args...)...)
	cmd.Dir = "../.."
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build %v: %v\n%s", args, err, b)
	}
}

type key struct{ sk, pk, npub string }

func newKey(t *testing.T) key {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	npub, _ := nip19.EncodePublicKey(pk)
	return key{sk, pk, npub}
}

func (k key) nip98(method, url string, body []byte) string {
	tags := nostr.Tags{{"u", url}, {"method", method}}
	if len(body) > 0 {
		s := sha256.Sum256(body)
		tags = append(tags, nostr.Tag{"payload", hex.EncodeToString(s[:])})
	}
	ev := nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: tags}
	ev.Sign(k.sk)
	b, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(b)
}

func boxCall(t *testing.T, base string, k key, method, path string, body []byte) (int, map[string]any) {
	req, _ := http.NewRequest(method, base+path, bytes.NewReader(body))
	req.Header.Set("Authorization", k.nip98(method, base+path, body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestBoxEndToEnd(t *testing.T) {
	dir := t.TempDir()
	havend, engine := filepath.Join(dir, "havend"), filepath.Join(dir, "haven-engine")
	build(t, havend, "-ldflags", "-X main.version=e2e", "./cmd/havend")
	build(t, engine, "-tags", "nolmdb", ".")

	owner, stranger := newKey(t), newKey(t)
	data := filepath.Join(dir, "data")
	vault := filepath.Join(data, "vault")
	mnt := filepath.Join(dir, "mnt")
	web := filepath.Join(dir, "web")
	os.MkdirAll(filepath.Join(mnt, "usb"), 0o755)
	os.MkdirAll(web, 0o755)
	os.WriteFile(filepath.Join(web, "index.html"), []byte("<title>NV web</title>"), 0o644)
	// No outside relays: nothing this test writes leaves the machine.
	os.MkdirAll(vault, 0o700)
	for _, f := range []string{"relays_import.json", "relays_blastr.json", "relays_dm.json"} {
		os.WriteFile(filepath.Join(vault, f), []byte("[]"), 0o600)
	}

	port, enginePort := freePort(t), freePort(t)
	cmd := exec.Command(havend)
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + dir,
		"NV_OWNER=" + owner.npub, "NV_DATA_DIR=" + data, "NV_PORT=" + strconv.Itoa(port),
		"NV_ENGINE_PORT=" + strconv.Itoa(enginePort), "NV_ENGINE_BIN=" + engine, "NV_WEB_DIR=" + web,
		"NV_MOVE_ROOT=" + mnt, "NV_DIRECTORY_RELAYS=ws://127.0.0.1:1",
	}
	logf, _ := os.Create(filepath.Join(dir, "havend.log"))
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cmd.Process.Signal(os.Interrupt)
		cmd.Wait()
		if t.Failed() {
			b, _ := os.ReadFile(filepath.Join(dir, "havend.log"))
			t.Logf("havend log:\n%s", b)
		}
	}()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	relayURL := "ws://127.0.0.1:" + strconv.Itoa(port)

	// Wait for the engine behind the front door (NIP-11).
	deadline := time.Now().Add(60 * time.Second)
	for {
		req, _ := http.NewRequest("GET", base+"/", nil)
		req.Header.Set("Accept", "application/nostr+json")
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 200 && bytes.Contains(b, []byte("Nostr Vault Public")) {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("engine never answered NIP-11 through the front door")
		}
		time.Sleep(300 * time.Millisecond)
	}

	// Web app at /.
	resp, err := http.Get(base + "/")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(b), "NV web") {
		t.Fatalf("GET / = %q", b)
	}

	// The device key exists and `havend device` prints the same npub.
	out, err := exec.Command("env", "NV_OWNER="+owner.npub, "NV_DATA_DIR="+data, havend, "device").Output()
	if err != nil {
		t.Fatal(err)
	}
	boxNpub := strings.TrimSpace(string(out))
	if !strings.HasPrefix(boxNpub, "npub1") {
		t.Fatalf("havend device = %q", out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Relay: the owner's note goes in and comes back out.
	relay, err := nostr.RelayConnect(ctx, relayURL)
	if err != nil {
		t.Fatal(err)
	}
	note := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "box e2e " + strconv.FormatInt(time.Now().UnixNano(), 10)}
	note.Sign(owner.sk)
	if err := relay.Publish(ctx, note); err != nil {
		t.Fatalf("publish note: %v", err)
	}
	// The owner lists the box in My Devices: a 10063 naming its mesh address.
	list := nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"server", "https://blossom.example/"}, {"server", "fipsmesh://" + boxNpub + "/"},
	}}
	list.Sign(owner.sk)
	if err := relay.Publish(ctx, list); err != nil {
		t.Fatalf("publish 10063: %v", err)
	}
	got, err := relay.QuerySync(ctx, nostr.Filter{IDs: []string{note.ID}})
	if err != nil || len(got) != 1 {
		t.Fatalf("note not read back: %v %v", got, err)
	}
	relay.Close()

	// Blossom: owner upload, public read.
	blob := []byte("box e2e blob " + note.ID)
	sum := sha256.Sum256(blob)
	hash := hex.EncodeToString(sum[:])
	auth := nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: "upload", Tags: nostr.Tags{
		{"t", "upload"}, {"x", hash}, {"expiration", strconv.FormatInt(time.Now().Add(5*time.Minute).Unix(), 10)},
	}}
	auth.Sign(owner.sk)
	ab, _ := json.Marshal(auth)
	req, _ := http.NewRequest("PUT", base+"/upload", bytes.NewReader(blob))
	req.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(ab))
	req.Header.Set("Content-Type", "text/plain")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rb, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		t.Fatalf("upload %d %s", resp.StatusCode, rb)
	}
	resp, err = http.Get(base + "/" + hash)
	if err != nil {
		t.Fatal(err)
	}
	gb, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(gb, blob) {
		t.Fatalf("blob read back %d %q", resp.StatusCode, gb)
	}

	// Box API: owner only.
	if code, _ := boxCall(t, base, stranger, "GET", "/api/box/status", nil); code != 403 {
		t.Fatalf("stranger status %d", code)
	}
	code, st := boxCall(t, base, owner, "GET", "/api/box/status", nil)
	if code != 200 || st["version"] != "e2e" || st["device"] != boxNpub {
		t.Fatalf("status %d %v", code, st)
	}
	t.Logf("status: %v", st)
	code, sto := boxCall(t, base, owner, "GET", "/api/box/storage", nil)
	if code != 200 || sto["blobCount"].(float64) != 1 || sto["databaseBytes"].(float64) == 0 || sto["otherBytes"].(float64) > 50<<20 {
		t.Fatalf("storage %d %v", code, sto)
	}
	code, dev := boxCall(t, base, owner, "GET", "/api/box/devices", nil)
	if code != 200 || dev["box"].(map[string]any)["approved"] != true || dev["source"] != "vault" {
		t.Fatalf("devices %d %v", code, dev)
	}
	code, upd := boxCall(t, base, owner, "POST", "/api/box/update", nil)
	if code != 202 || upd["via"] != "file" {
		t.Fatalf("update %d %v", code, upd)
	}

	// Move the vault to the "USB disk"; the note is still there afterwards.
	target := filepath.Join(mnt, "usb", "vault")
	code, mv := boxCall(t, base, owner, "POST", "/api/box/move", []byte(fmt.Sprintf(`{"path":%q}`, target)))
	if code != 202 {
		t.Fatalf("move %d %v", code, mv)
	}
	deadline = time.Now().Add(60 * time.Second)
	for {
		_, st = boxCall(t, base, owner, "GET", "/api/box/status", nil)
		if m, ok := st["move"].(map[string]any); ok && (m["phase"] == "done" || m["phase"] == "failed") {
			if m["phase"] != "done" {
				t.Fatalf("move failed: %v", m)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("move did not finish: %v", st["move"])
		}
		time.Sleep(300 * time.Millisecond)
	}
	if _, err := os.Stat(vault); !os.IsNotExist(err) {
		t.Fatalf("old vault still at %s", vault)
	}
	deadline = time.Now().Add(60 * time.Second)
	for {
		ctx2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
		r, err := nostr.RelayConnect(ctx2, relayURL)
		if err == nil {
			got, err = r.QuerySync(ctx2, nostr.Filter{IDs: []string{note.ID}})
			r.Close()
		}
		cancel2()
		if err == nil && len(got) == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("note not readable after the move: %v", err)
		}
		time.Sleep(500 * time.Millisecond)
	}
	resp, err = http.Get(base + "/" + hash)
	if err != nil {
		t.Fatal(err)
	}
	gb, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(gb, blob) {
		t.Fatalf("blob after move %d", resp.StatusCode)
	}
}
