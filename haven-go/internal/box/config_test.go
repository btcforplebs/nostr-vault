package box

import (
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr/nip19"
)

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestConfigNeedsOwner(t *testing.T) {
	if _, err := ConfigFromEnv(envOf(nil)); err == nil || !strings.Contains(err.Error(), "NV_OWNER") {
		t.Fatalf("no owner: want NV_OWNER error, got %v", err)
	}
}

func TestParseOwnerForms(t *testing.T) {
	k := newTestKey(t)
	npub, _ := nip19.EncodePublicKey(k.pk)
	for _, in := range []string{npub, "nostr:" + npub, k.pk, strings.ToUpper(k.pk), "  " + npub + "\n"} {
		h, n, err := ParseOwner(in)
		if err != nil || h != k.pk || n != npub {
			t.Fatalf("ParseOwner(%q) = %q %q %v", in, h, n, err)
		}
	}
	nsec, _ := nip19.EncodePrivateKey(k.sk)
	if _, _, err := ParseOwner(nsec); err == nil || !strings.Contains(err.Error(), "nsec") {
		t.Fatalf("nsec must be refused, got %v", err)
	}
	for _, bad := range []string{"npub1xyz", "abc", strings.Repeat("g", 64)} {
		if _, _, err := ParseOwner(bad); err == nil {
			t.Fatalf("ParseOwner(%q) should fail", bad)
		}
	}
}

func TestConfigDefaultsAndPorts(t *testing.T) {
	k := newTestKey(t)
	c, err := ConfigFromEnv(envOf(map[string]string{"NV_OWNER": k.pk}))
	if err != nil {
		t.Fatal(err)
	}
	if c.DataDir != "/data" || c.Port != 8080 || c.EnginePort != 3355 || c.MoveRoot != "/mnt" {
		t.Fatalf("defaults: %+v", c)
	}
	if c.MeshStatusFile != "/data/mesh/status.json" || c.BoxDir() != "/data/box" || c.DefaultVaultDir() != "/data/vault" {
		t.Fatalf("paths: %+v", c)
	}
	for _, env := range []map[string]string{
		{"NV_OWNER": k.pk, "NV_PORT": "0"},
		{"NV_OWNER": k.pk, "NV_PORT": "x"},
		{"NV_OWNER": k.pk, "NV_ENGINE_PORT": "8080"},
		{"NV_OWNER": k.pk, "NV_DATA_DIR": "data"},
	} {
		if _, err := ConfigFromEnv(envOf(env)); err == nil {
			t.Fatalf("%v should fail", env)
		}
	}
}

func TestEngineEnvIsTheMacsWithLoopbackBind(t *testing.T) {
	k := newTestKey(t)
	c, _ := ConfigFromEnv(envOf(map[string]string{"NV_OWNER": k.pk, "NV_ENGINE_PORT": "4000"}))
	env := EngineEnv(c, "/v")
	want := map[string]string{
		"OWNER_NPUB": c.OwnerNpub, "RELAY_PORT": "4000", "RELAY_BIND_ADDRESS": "127.0.0.1",
		"DB_ENGINE": "badger", "DATABASE_PATH": "/v/data/", "BLOSSOM_PATH": "/v/blossom/",
		"HAVEN_ENABLE_TLS": "0", "INBOX_PULL_INTERVAL_SECONDS": "900",
	}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("%s = %q, want %q", k, env[k], v)
		}
	}
	list := EngineEnvList(c, "/v", envOf(map[string]string{"PATH": "/bin", "NV_OWNER": "x", "SECRET": "y"}))
	joined := strings.Join(list, "\n")
	if strings.Contains(joined, "NV_OWNER=") || strings.Contains(joined, "SECRET=") || !strings.Contains(joined, "PATH=/bin") {
		t.Fatalf("engine env must be clean:\n%s", joined)
	}
}

// The mesh door is NV_PORT+1 unless set, never one of the other two ports, and
// the engine gets it as HAVEN_MESH_PLAIN_PORT (linux/mesh/README.md), with
// HAVEN_BEHIND_PROXY so it rate-limits clients, not havend's loopback.
func TestMeshDoorPortReachesTheEngine(t *testing.T) {
	k := newTestKey(t)
	c, err := ConfigFromEnv(envOf(map[string]string{"NV_OWNER": k.pk}))
	if err != nil {
		t.Fatal(err)
	}
	if c.MeshDoorPort != 8081 || c.MeshNpubFile != "/data/mesh/npub" || c.MeshDevicesFile != "/data/mesh-devices.json" {
		t.Fatalf("mesh defaults: %+v", c)
	}
	env := EngineEnv(c, "/v")
	if env["HAVEN_MESH_PLAIN_PORT"] != "8081" || env["HAVEN_BEHIND_PROXY"] != "1" {
		t.Fatalf("engine env: door %q proxy %q", env["HAVEN_MESH_PLAIN_PORT"], env["HAVEN_BEHIND_PROXY"])
	}
	joined := strings.Join(EngineEnvList(c, "/v", envOf(nil)), "\n")
	if !strings.Contains(joined, "HAVEN_MESH_PLAIN_PORT=8081") {
		t.Fatalf("exec env drops the door port:\n%s", joined)
	}
	c, err = ConfigFromEnv(envOf(map[string]string{"NV_OWNER": k.pk, "NV_PORT": "9000", "NV_MESH_DOOR_PORT": "9100", "NV_MESH_DEVICES": "/x/d.json"}))
	if err != nil || c.MeshDoorPort != 9100 || c.MeshDevicesFile != "/x/d.json" {
		t.Fatalf("set: %+v %v", c, err)
	}
	if c, _ := ConfigFromEnv(envOf(map[string]string{"NV_OWNER": k.pk, "NV_PORT": "9000"})); c.MeshDoorPort != 9001 {
		t.Fatalf("door follows NV_PORT: %d", c.MeshDoorPort)
	}
	for _, env := range []map[string]string{
		{"NV_OWNER": k.pk, "NV_MESH_DOOR_PORT": "8080"},
		{"NV_OWNER": k.pk, "NV_MESH_DOOR_PORT": "3355"},
		{"NV_OWNER": k.pk, "NV_MESH_DOOR_PORT": "x"},
		{"NV_OWNER": k.pk, "NV_PORT": "65535"},
		{"NV_OWNER": k.pk, "NV_MESH_DEVICES": "rel.json"},
	} {
		if _, err := ConfigFromEnv(envOf(env)); err == nil {
			t.Fatalf("%v should fail", env)
		}
	}
}
