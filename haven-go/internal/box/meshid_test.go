package box

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The box has one npub, the mesh's. Until nv-mesh has written it there is
// none, and nothing can approve the box.
func TestMeshIDIsTheBoxsOnlyIdentity(t *testing.T) {
	dir := t.TempDir()
	m := MeshID{NpubFile: filepath.Join(dir, "npub")}
	if _, _, ok := m.Read(); ok {
		t.Fatal("no file read as an npub")
	}
	k := newTestKey(t)
	npub := npubOf(t, k)
	for _, bad := range []string{"", "garbage", strings.ToUpper(npub), "nsec1" + npub[5:], npub[:20]} {
		os.WriteFile(m.NpubFile, []byte(bad), 0o644)
		if _, _, ok := m.Read(); ok {
			t.Fatalf("%q read as an npub", bad)
		}
	}
	os.WriteFile(m.NpubFile, []byte(npub+"\n"), 0o644)
	got, pk, ok := m.Read()
	if !ok || got != npub || pk != k.pk {
		t.Fatalf("read %q %q %v", got, pk, ok)
	}

	// Mesh not up yet: no address to paste, no approval even from a list
	// that names some device, and a hint that says why.
	owner := newTestKey(t)
	list := owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"server", "fipsmesh://" + npub + "/"}}})
	r := BuildDevicesReport("", "", list, "vault")
	if r.Box.Npub != "" || r.Box.Address != "" || r.Box.Approved || !strings.Contains(r.Hint, "starting") {
		t.Fatalf("mesh not up: %+v", r)
	}
}

func readDevicesFile(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var list []struct {
		Npub string `json:"npub"`
	}
	if err := json.Unmarshal(b, &list); err != nil {
		t.Fatalf("%s is not nv-mesh's shape: %v\n%s", path, err, b)
	}
	out := []string{}
	for _, d := range list {
		out = append(out, d.Npub)
	}
	return out
}

// mesh-devices.json follows the owner's newest 10063: the owner's other mesh
// devices, never the box, and only while the list names the box.
func TestMeshDevicesFileFollowsTheOwnersList(t *testing.T) {
	owner, boxKey, phone, mac := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone, nMac := npubOf(t, boxKey), npubOf(t, phone), npubOf(t, mac)
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	src := &fakeLists{}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file}
	ctx := context.Background()
	at := nostr.Now()
	list := func(npubs ...string) *nostr.Event {
		at++
		tags := nostr.Tags{{"server", "https://blossom.example/"}}
		for _, n := range npubs {
			tags = append(tags, nostr.Tag{"server", "fipsmesh://" + n + "/"})
		}
		return owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: at, Tags: tags})
	}

	d.Refresh(ctx)
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatalf("no list found, yet the file was written: %v", err)
	}

	src.ev, src.src = list(nPhone, nMac), "vault"
	d.Refresh(ctx)
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("box not approved, devices %v", got)
	}

	src.ev = list(nPhone, nBox, nMac)
	d.Refresh(ctx)
	if got := readDevicesFile(t, file); strings.Join(got, ",") != nPhone+","+nMac {
		t.Fatalf("approved: devices %v", got)
	}
	if st, _ := os.Stat(file); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v: nv-mesh runs as another uid and must read it", st.Mode().Perm())
	}

	// An outage (no list anywhere) keeps the last good file.
	src.ev, src.src = nil, "none"
	d.Refresh(ctx)
	if got := readDevicesFile(t, file); len(got) != 2 {
		t.Fatalf("outage dropped devices: %v", got)
	}

	// A removed device drops; a removed box drops everyone.
	src.ev, src.src = list(nBox, nMac), "relays"
	d.Refresh(ctx)
	if got := readDevicesFile(t, file); strings.Join(got, ",") != nMac {
		t.Fatalf("phone removed: devices %v", got)
	}
	src.ev = list(nMac)
	d.Refresh(ctx)
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("box removed: devices %v", got)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(file), ".mesh-devices.*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

// An unchanged list leaves the file alone: nv-mesh restarts its engine on
// every change it sees.
func TestMeshDevicesFileUntouchedWhenUnchanged(t *testing.T) {
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	if changed, err := writeMeshDevices(file, []string{"npub1a"}); err != nil || !changed {
		t.Fatalf("first write %v %v", changed, err)
	}
	old := time.Now().Add(-time.Hour)
	os.Chtimes(file, old, old)
	if changed, err := writeMeshDevices(file, []string{"npub1a"}); err != nil || changed {
		t.Fatalf("same list rewritten %v %v", changed, err)
	}
	if st, _ := os.Stat(file); !st.ModTime().Equal(old) {
		t.Fatal("file touched")
	}
}

// status.json as nv-mesh writes it (linux/mesh/README.md) reads as the
// screens' {up, npub, peers}.
func TestMeshStatusIsNvMeshsShape(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	path := filepath.Join(t.TempDir(), "status.json")
	write := func(s string) { os.WriteFile(path, []byte(s), 0o644) }
	upd := `"updated":1800000000`

	write(`{"running":true,"npub":"npub1mesh","peers":["npub1x","npub1y"],"devices":2,"error":null,` + upd + `}`)
	m := readMesh(path, "npub1box", now)
	if m["up"] != true || m["peers"] != 2 || m["npub"] != "npub1mesh" || m["devices"] != float64(2) {
		t.Fatalf("running: %v", m)
	}
	write(`{"running":true,"peers":[],` + upd + `}`)
	if m := readMesh(path, "npub1box", now); m["up"] != true || m["peers"] != 0 || m["npub"] != "npub1box" {
		t.Fatalf("no peers: %v", m)
	}
	write(`{"running":false,"peers":[],"error":"add a device",` + upd + `}`)
	if m := readMesh(path, "", now); m["up"] != false || m["error"] != "add a device" {
		t.Fatalf("stopped: %v", m)
	}
	// nv-mesh stopped writing a minute ago: the last "running" is stale.
	write(`{"running":true,"peers":[],` + upd + `}`)
	if m := readMesh(path, "", now.Add(time.Minute)); m["up"] != false {
		t.Fatalf("stale file read as up: %v", m)
	}
	// "up" is havend's word, not nv-mesh's: a file claiming it does not count.
	write(`{"up":true,"peers":3}`)
	if m := readMesh(path, "", now); m["up"] != false || m["peers"] != 0 {
		t.Fatalf("foreign up: %v", m)
	}
	os.Remove(path)
	if m := readMesh(path, "npub1box", now); m["up"] != false || m["peers"] != 0 || m["npub"] != "npub1box" {
		t.Fatalf("no file: %v", m)
	}
}

// A read of an older list that lands after a newer one never undoes it.
func TestMeshDevicesFileNeverGoesBackInTime(t *testing.T) {
	owner, boxKey, phone := newTestKey(t), newTestKey(t), newTestKey(t)
	nBox, nPhone := npubOf(t, boxKey), npubOf(t, phone)
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	src := &fakeLists{src: "vault"}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file}
	older := owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"server", "fipsmesh://" + nBox + "/"}, {"server", "fipsmesh://" + nPhone + "/"}}})
	newer := owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now() + 5, Tags: nostr.Tags{
		{"server", "fipsmesh://" + nBox + "/"}}})
	src.ev = newer
	d.Refresh(context.Background())
	src.ev = older
	d.Refresh(context.Background())
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("older list re-admitted %v", got)
	}
}
