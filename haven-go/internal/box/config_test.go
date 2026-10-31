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
