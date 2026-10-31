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

// lanIP is one of this machine's non-loopback IPv4 addresses, or "".
func lanIP() string {
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLoopback() && !n.IP.IsLinkLocalUnicast() {
			return n.IP.String()
		}
	}
	return ""
}

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

	// nv-mesh's npub file, as it writes it on first start: the box's one
	// npub (a throwaway key).
	meshKey, phone := newKey(t), newKey(t)
	os.MkdirAll(filepath.Join(data, "mesh"), 0o755)
	os.WriteFile(filepath.Join(data, "mesh", "npub"), []byte(meshKey.npub+"\n"), 0o644)

	port, enginePort, doorPort := freePort(t), freePort(t), freePort(t)
	cmd := exec.Command(havend)
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + dir,
		"NV_OWNER=" + owner.npub, "NV_DATA_DIR=" + data, "NV_PORT=" + strconv.Itoa(port),
		"NV_ENGINE_PORT=" + strconv.Itoa(enginePort), "NV_ENGINE_BIN=" + engine, "NV_WEB_DIR=" + web,
		"NV_MOVE_ROOT=" + mnt, "NV_DIRECTORY_RELAYS=ws://127.0.0.1:1",
		"NV_MESH_DOOR_PORT=" + strconv.Itoa(doorPort),
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

	// One box npub: `havend device` prints the mesh's, and havend made no
	// key of its own.
	out, err := exec.Command("env", "NV_OWNER="+owner.npub, "NV_DATA_DIR="+data, havend, "device").Output()
	if err != nil {
		t.Fatal(err)
	}
	boxNpub := strings.TrimSpace(string(out))
	if boxNpub != meshKey.npub {
		t.Fatalf("havend device = %q, want the mesh npub %s", out, meshKey.npub)
	}
	if _, err := os.Stat(filepath.Join(data, "box", "device.key")); !os.IsNotExist(err) {
		t.Fatalf("havend made a second key: %v", err)
	}

	// The mesh door is open on loopback for strangers, and closed to all but
	// what a mesh peer may ask.
	if resp, err := http.Get("http://127.0.0.1:" + strconv.Itoa(doorPort) + "/"); err != nil {
		t.Fatalf("mesh door not open: %v", err)
	} else if resp.Body.Close(); resp.StatusCode != 404 {
		t.Fatalf("mesh door GET / = %d, want 404", resp.StatusCode)
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
	// The owner lists the box in My Devices: a 10063 naming its mesh address,
	// next to the owner's phone.
	list := nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"server", "https://blossom.example/"}, {"server", "fipsmesh://" + boxNpub + "/"},
		{"server", "fipsmesh://" + phone.npub + "/"},
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

	// NIP-42: the owner can AUTH under whichever name reached the box (the web
	// re-signs AUTH as the owner for the URL it connected to), not only the
	// engine's own 127.0.0.1:<engine port>.
	for _, host := range []string{"127.0.0.1", "localhost"} {
		privURL := "ws://" + host + ":" + strconv.Itoa(port) + "/private"
		pr, err := nostr.RelayConnect(ctx, privURL)
		if err != nil {
			t.Fatalf("connect %s: %v", privURL, err)
		}
		time.Sleep(500 * time.Millisecond) // the challenge arrives on connect
		if err := pr.Auth(ctx, func(e *nostr.Event) error { return e.Sign(owner.sk) }); err != nil {
			t.Fatalf("owner AUTH at %s refused: %v", privURL, err)
		}
		pn := nostr.Event{Kind: 1, CreatedAt: nostr.Now(), Content: "private via " + host}
		pn.Sign(owner.sk)
		if err := pr.Publish(ctx, pn); err != nil {
			t.Fatalf("owner publish at %s after AUTH: %v", privURL, err)
		}
		pr.Close()
	}

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
	// nv-mesh's status.json, as it writes it every 5 s.
	os.WriteFile(filepath.Join(data, "mesh", "status.json"),
		[]byte(fmt.Sprintf(`{"running":true,"peers":[],"devices":1,"error":null,"updated":%d}`, time.Now().Unix())), 0o644)
	code, st := boxCall(t, base, owner, "GET", "/api/box/status", nil)
	if code != 200 || st["version"] != "e2e" || st["device"] != boxNpub {
		t.Fatalf("status %d %v", code, st)
	}
	if m := st["mesh"].(map[string]any); m["up"] != true || m["peers"] != float64(0) {
		t.Fatalf("mesh %v: nv-mesh's running status should read as up", m)
	}
	t.Logf("status: %v", st)
	code, sto := boxCall(t, base, owner, "GET", "/api/box/storage", nil)
	if code != 200 || sto["blobCount"].(float64) != 1 || sto["databaseBytes"].(float64) == 0 || sto["otherBytes"].(float64) > 50<<20 {
		t.Fatalf("storage %d %v", code, sto)
	}
	code, dev := boxCall(t, base, owner, "GET", "/api/box/devices", nil)
	if code != 200 || dev["box"].(map[string]any)["approved"] != true || dev["source"] != "vault" ||
		dev["box"].(map[string]any)["npub"] != boxNpub {
		t.Fatalf("devices %d %v", code, dev)
	}
	// ... and nv-mesh's list now holds the phone, not the box.
	devFile, err := os.ReadFile(filepath.Join(data, "mesh-devices.json"))
	if err != nil {
		t.Fatalf("mesh-devices.json not written: %v", err)
	}
	if !strings.Contains(string(devFile), phone.npub) || strings.Contains(string(devFile), boxNpub) {
		t.Fatalf("mesh-devices.json = %s", devFile)
	}

	// A client on the LAN (this machine's own LAN address, so it arrives as
	// that address, not loopback) faces the private relay's connection limit:
	// a burst of 9, not 30 of 30.
	// macOS's application firewall drops LAN connections to a freshly built
	// binary; then the check is skipped (the root package's
	// TestBoxFrontDoorRateLimitsTheRealClient covers it in-process).
	lan := lanIP()
	if lan != "" {
		probe := &http.Client{Timeout: 3 * time.Second}
		if resp, err := probe.Get("http://" + net.JoinHostPort(lan, strconv.Itoa(port)) + "/"); err != nil {
			t.Logf("LAN address %s unreachable (%v): rate-limit check skipped", lan, err)
			lan = ""
		} else {
			resp.Body.Close()
		}
	}
	if lan != "" {
		lanURL := "ws://" + net.JoinHostPort(lan, strconv.Itoa(port)) + "/private"
		accepted := 0
		for i := 0; i < 30; i++ {
			c2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
			r, err := nostr.RelayConnect(c2, lanURL)
			cancel2()
			if err == nil {
				accepted++
				r.Close()
			}
		}
		if accepted != 9 {
			t.Fatalf("LAN client %s: %d/30 connections accepted, want the burst of 9", lan, accepted)
		}
		// The box's own loopback stays unlimited.
		for i := 0; i < 12; i++ {
			c2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
			r, err := nostr.RelayConnect(c2, "ws://127.0.0.1:"+strconv.Itoa(port)+"/private")
			cancel2()
			if err != nil {
				t.Fatalf("loopback connection %d refused: %v", i, err)
			}
			r.Close()
		}
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
