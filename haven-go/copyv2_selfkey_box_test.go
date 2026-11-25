//go:build !cshared && !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/barrydeen/haven/internal/box"
)

// Tron, P12 finding 1 (Logen go e3517d34): a box whose havend cannot read
// nv-mesh's npub writes a devices file with no self. An empty self used to
// skip the paired check in the copy-token gate, so any unexpired copy token
// got the whole copy. Now the box refuses every copy token until it knows its
// own mesh key, and lets the paired phone back in once it does.
func TestBoxRefusesCopyTokensUntilItKnowsItsOwnMeshKey(t *testing.T) {
	owner, vaultKey, phone := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, newTestKey(t)) // a fresh set, restored after the test
	prevRequired := meshSelfRequired.Load()
	t.Cleanup(func() { meshSelfRequired.Store(prevRequired) })

	// nv-mesh has not written its npub yet (or havend cannot read it); its
	// device list already names the phone.
	meshDir := t.TempDir()
	npubFile := filepath.Join(meshDir, "npub")
	meshList := filepath.Join(meshDir, "mesh-devices.json")
	if err := os.WriteFile(meshList, []byte(`[{"npub":"`+npubOf(t, phone.pk)+`"}]`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	devices := filepath.Join(t.TempDir(), "engine-mesh-devices.json")
	writer := &box.EngineDevices{Mesh: box.MeshID{NpubFile: npubFile}, From: meshList, To: devices}
	if _, err := writer.Sync(); err != nil {
		t.Fatal(err)
	}

	// The engine follows the file the way the box starts it.
	t.Setenv("HAVEN_MESH_DEVICES_FILE", devices)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	startMeshDevicesFile(ctx)
	if meshDevices.selfKey() != "" {
		t.Fatal("the engine has a self key with no npub to read")
	}

	_, s := copySyncPair(t, owner)
	token := copyPeerToken("npub1peer")
	s.tokens[0].Device = phone.pk
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	aDir := t.TempDir()
	config.WotCachePath = filepath.Join(aDir, "wot_cache.json")
	writeTrustFile(t, aDir, owner.pk, 100)

	// No self: the phone's live token, and any other, is refused.
	if resp := trustGet(t, ts.URL, "?account="+owner.pk, token); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a copy token was served while the box had no self key: %d", resp.StatusCode)
	}
	if _, ok := s.bearer(bearerRequest(token)); ok {
		t.Fatal("bearer accepted a copy token while the box had no self key")
	}

	// nv-mesh's npub appears: havend writes the self, the engine reads it,
	// and the paired phone's token is good again.
	if err := os.WriteFile(npubFile, []byte(npubOf(t, vaultKey.pk)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if changed, err := writer.Sync(); err != nil || !changed {
		t.Fatalf("havend did not write the self: changed %v, %v", changed, err)
	}
	(&meshDevicesFile{path: devices}).load()
	if meshDevices.selfKey() != vaultKey.pk {
		t.Fatal("the engine did not take the box's mesh key")
	}
	if resp := trustGet(t, ts.URL, "?account="+owner.pk, token); resp.StatusCode != http.StatusOK {
		t.Fatalf("the paired phone was refused once the box knew its key: %d", resp.StatusCode)
	}
}

// Without a devices file (the apps before SetMeshDevicesC) an empty self
// keeps the old rule: the token is good.
func TestCopyTokenWithNoDevicesFileKeepsTheOldRule(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	prev := meshDevices // no set handed over yet: no self
	meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: prev.now}
	t.Cleanup(func() { meshDevices = prev })
	prevRequired := meshSelfRequired.Load()
	meshSelfRequired.Store(false)
	t.Cleanup(func() { meshSelfRequired.Store(prevRequired) })

	_, s := copySyncPair(t, owner)
	token := copyPeerToken("npub1peer")
	if _, ok := s.bearer(bearerRequest(token)); !ok {
		t.Fatal("a token was refused with no devices file and no self")
	}
}

func bearerRequest(token string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/copy/v2/sync/trust", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	return r
}
