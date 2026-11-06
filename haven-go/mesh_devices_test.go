//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// The mesh never uses the account key: paired devices sign with their own
// mesh key (docs/MESH_COPY_V2_CONTRACT.md §2, §2.1). All keys are throwaway.

// pairMeshDevices sets this vault's mesh key and paired set for one test.
func pairMeshDevices(t *testing.T, self testKey, devices ...testKey) {
	t.Helper()
	prev := meshDevices
	meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
	t.Cleanup(func() { meshDevices = prev })
	if err := meshDevices.set(meshSetJSON(t, self, devices...)); err != nil {
		t.Fatal(err)
	}
}

func meshSetJSON(t *testing.T, self testKey, devices ...testKey) string {
	t.Helper()
	npub := func(pk string) string { n, _ := nip19.EncodePublicKey(pk); return n }
	in := map[string]any{"self": npub(self.pk)}
	var list []map[string]string
	for _, d := range devices {
		list = append(list, map[string]string{"npub": npub(d.pk), "role": "phone"})
	}
	in["devices"] = list
	raw, _ := json.Marshal(in)
	return string(raw)
}

// deviceStartProof: B's start proof signed by its mesh key, naming vault p.
func deviceStartProof(t *testing.T, k testKey, p string, at nostr.Timestamp, extra ...nostr.Tag) string {
	t.Helper()
	tags := nostr.Tags{{"u", "http://127.0.0.1:9/copy/v2/start"}, {"method", "POST"}}
	if p != "" {
		tags = append(tags, nostr.Tag{"p", p})
	}
	tags = append(tags, extra...)
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: at, Tags: tags})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

// deviceBlobAuth: a kind 24242 for verb on sha, signed by k for vault p.
func deviceBlobAuth(t *testing.T, k testKey, verb, sha, p string, exp time.Time) string {
	t.Helper()
	tags := nostr.Tags{{"t", verb}, {"expiration", fmt.Sprint(exp.Unix())}}
	if sha != "" {
		tags = append(tags, nostr.Tag{"x", sha})
	}
	if p != "" {
		tags = append(tags, nostr.Tag{"p", p})
	}
	ev := k.sign(t, nostr.Event{Kind: 24242, Content: nostr.GeneratePrivateKey(), Tags: tags})
	raw, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(raw)
}

func TestCopyStartDeviceKey(t *testing.T) {
	owner, vault, phone, stranger, otherVault := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, vault, phone)
	s := newTestCopyServer(failingBuild)
	now := nostr.Now()
	good := deviceStartProof(t, phone, vault.pk, now)
	cases := []struct {
		name string
		auth string
		want int
	}{
		{"an unpaired key", deviceStartProof(t, stranger, vault.pk, now), 403},
		{"the vault's own key", deviceStartProof(t, vault, vault.pk, now), 403},
		{"for another of the owner's vaults", deviceStartProof(t, phone, otherVault.pk, now), 401},
		{"naming no vault", deviceStartProof(t, phone, "", now), 401},
		{"stale", deviceStartProof(t, phone, vault.pk, now-120), 401},
		{"from too far ahead", deviceStartProof(t, phone, vault.pk, now+120), 401},
		{"naming another device", deviceStartProof(t, phone, vault.pk, now, nostr.Tag{"device", stranger.pk}), 401},
		{"naming itself as the device", deviceStartProof(t, phone, vault.pk, now, nostr.Tag{"device", phone.pk}), 200},
		{"the paired phone", good, 200},
		{"the same proof again", good, 401},
	}
	for _, c := range cases {
		if code, _, _ := startAs(t, s, c.auth); code != c.want {
			t.Errorf("%s: %d, want %d", c.name, code, c.want)
		}
	}
	// The token is bound to the signer: one per device, so two 200s above
	// left one token, and it is the phone's.
	s.mu.Lock()
	n, dev := len(s.tokens), ""
	if n == 1 {
		dev = s.tokens[0].Device
	}
	s.mu.Unlock()
	if n != 1 || dev != phone.pk {
		t.Fatalf("tokens: %d, device %q; want 1 bound to the phone", n, dev)
	}
	// The owner-key form still works until the apps switch.
	if code, _, _ := startAs(t, s, startProofFor(t, owner, testDevice)); code != 200 {
		t.Errorf("owner-signed start: %d, want 200", code)
	}
}

// Unpair: the device leaves the set and its tokens go at once; an empty set
// accepts no device rather than anyone.
func TestUnpairRevokesAndEmptySetRefuses(t *testing.T) {
	owner, vault, phone := newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, vault, phone)
	prev := copyV2
	copyV2 = newTestCopyServer(failingBuild)
	t.Cleanup(func() { copyV2 = prev })

	code, id, token := startAs(t, copyV2, deviceStartProof(t, phone, vault.pk, nostr.Now()))
	if code != 200 {
		t.Fatalf("start: %d", code)
	}
	if got := getWith(copyV2, "/copy/v2/"+id, token, "", nil); got != 200 {
		t.Fatalf("paired read: %d", got)
	}
	if err := meshDevices.set(meshSetJSON(t, vault)); err != nil {
		t.Fatal(err)
	}
	if got := getWith(copyV2, "/copy/v2/"+id, token, "", nil); got != 401 {
		t.Errorf("token after unpair: %d, want 401", got)
	}
	if code, _, _ := startAs(t, copyV2, deviceStartProof(t, phone, vault.pk, nostr.Now())); code != 403 {
		t.Errorf("start after unpair (empty set): %d, want 403", code)
	}
	// Bad input keeps the old set.
	for _, bad := range []string{"nope", `{"devices":[{"npub":"npub1x"}]}`, `{"self":"x","devices":[{}]}`} {
		if err := meshDevices.set(bad); err == nil {
			t.Errorf("set(%q) accepted", bad)
		}
	}
	// Never set at all: nothing is paired.
	empty := &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
	if empty.paired(phone.pk) {
		t.Error("an unset vault accepted a device")
	}
}

// Blossom over the mesh door with the device's own key: accepted when
// paired and made for this vault, once; refused otherwise. The record is
// filed under the owner, so the copy's own-media set counts it.
func TestMeshDoorDeviceKeyBlossom(t *testing.T) {
	h := startHaven(t)
	config.OwnerPubKey = h.owner
	door := startMeshDoor(t)
	vault, phone, stranger, otherVault := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)

	body := []byte("photo from the paired phone")
	sum := sha256.Sum256(body)
	sha := hex.EncodeToString(sum[:])
	soon := time.Now().Add(4 * time.Minute)

	refused := []struct {
		name string
		auth string
		want int
	}{
		{"an unpaired key", deviceBlobAuth(t, stranger, "upload", sha, vault.pk, soon), 403},
		{"the vault's own key", deviceBlobAuth(t, vault, "upload", sha, vault.pk, soon), 403},
		{"for another vault", deviceBlobAuth(t, phone, "upload", sha, otherVault.pk, soon), 403},
		{"naming no vault", deviceBlobAuth(t, phone, "upload", sha, "", soon), 403},
		{"a get token", deviceBlobAuth(t, phone, "get", sha, vault.pk, soon), 403},
		{"for another blob", deviceBlobAuth(t, phone, "upload", strings.Repeat("ab", 32), vault.pk, soon), 403},
		{"expired", deviceBlobAuth(t, phone, "upload", sha, vault.pk, time.Now().Add(-time.Second)), 401},
		{"living over 5 minutes", deviceBlobAuth(t, phone, "upload", sha, vault.pk, time.Now().Add(10*time.Minute)), 401},
	}
	for _, c := range refused {
		if got := meshPut(t, door, c.auth, body); got != c.want {
			t.Errorf("upload, %s: %d, want %d", c.name, got, c.want)
		}
	}
	good := deviceBlobAuth(t, phone, "upload", sha, vault.pk, soon)
	if got := meshPut(t, door, good, body); got != 200 {
		t.Fatalf("paired upload: %d, want 200", got)
	}
	if got := meshPut(t, door, good, body); got != http.StatusConflict {
		t.Errorf("replayed upload: %d, want 409", got)
	}

	own, err := copyOwnMediaSet(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !own[sha] {
		t.Error("the phone's upload is not in the owner's own media (record not filed under the owner)")
	}

	// Read it back over the door with a device get; a replay is refused.
	get := deviceBlobAuth(t, phone, "get", sha, vault.pk, soon)
	read := func(method, auth string) int {
		req, _ := http.NewRequest(method, door+"/"+sha, nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if got := read(http.MethodGet, deviceBlobAuth(t, stranger, "get", sha, vault.pk, soon)); got != 404 {
		t.Errorf("stranger get of an unposted blob: %d, want 404", got)
	}
	if got := read(http.MethodHead, get); got != 200 {
		t.Errorf("paired HEAD check: %d, want 200", got)
	}
	if got := read(http.MethodGet, get); got != 200 {
		t.Errorf("paired get: %d, want 200", got)
	}
	if got := read(http.MethodGet, get); got != http.StatusConflict {
		t.Errorf("replayed get: %d, want 409", got)
	}
}

// The own-device port (the full relay handler): upload, check and delete by
// the paired phone's key. Delete only removes the owner's record.
func TestOwnPortDeviceKeyUploadAndDelete(t *testing.T) {
	h := startHaven(t)
	config.OwnerPubKey = h.owner
	base := strings.Replace(h.base, "ws://", "http://", 1)
	vault, phone, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)
	soon := time.Now().Add(4 * time.Minute)

	do := func(method, path, auth string, body []byte) int {
		req, _ := http.NewRequest(method, base+path, bytes.NewReader(body))
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		req.Header.Set("Content-Type", "text/plain")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	body := []byte("own port upload")
	sum := sha256.Sum256(body)
	sha := hex.EncodeToString(sum[:])
	// A token for another blob cannot put this one here (the index checks x).
	if got := do(http.MethodPut, "/upload", deviceBlobAuth(t, phone, "upload", strings.Repeat("cd", 32), vault.pk, soon), body); got == 200 {
		t.Error("upload under a token for another blob was stored")
	}
	if got := do(http.MethodPut, "/upload", deviceBlobAuth(t, stranger, "upload", sha, vault.pk, soon), body); got != 403 {
		t.Errorf("stranger upload: %d, want 403", got)
	}
	if got := do(http.MethodPut, "/upload", deviceBlobAuth(t, phone, "upload", sha, vault.pk, soon), body); got != 200 {
		t.Fatalf("paired upload: %d, want 200", got)
	}
	bd, err := blossomServer.Store.Get(context.Background(), sha)
	if err != nil || bd == nil || bd.Owner != h.owner {
		t.Fatalf("record: %+v, %v; want filed under the owner", bd, err)
	}

	// A stranger's delete only ever drops the stranger's own record (none):
	// the owner's blob stays.
	_ = do(http.MethodDelete, "/"+sha, deviceBlobAuth(t, stranger, "delete", sha, vault.pk, soon), nil)
	if got := do(http.MethodHead, "/"+sha, "", nil); got != 200 {
		t.Errorf("blob after a stranger's delete: %d, want 200 (kept)", got)
	}
	// Delete everywhere: one event naming several vaults; this one is among them.
	del := func() string {
		ev := phone.sign(t, nostr.Event{Kind: 24242, Tags: nostr.Tags{{"t", "delete"}, {"x", sha},
			{"p", stranger.pk}, {"p", vault.pk}, {"expiration", fmt.Sprint(soon.Unix())}}})
		raw, _ := json.Marshal(ev)
		return "Nostr " + base64.StdEncoding.EncodeToString(raw)
	}()
	if got := do(http.MethodDelete, "/"+sha, del, nil); got != 200 {
		t.Fatalf("paired delete: %d, want 200", got)
	}
	if got := do(http.MethodDelete, "/"+sha, del, nil); got != http.StatusConflict {
		t.Errorf("replayed delete: %d, want 409", got)
	}
	if got := do(http.MethodHead, "/"+sha, "", nil); got != 404 {
		t.Errorf("check after delete: %d, want 404", got)
	}

	// A blob whose only record is another account's is not the owner's: a
	// device delete leaves it.
	other := newTestKey(t)
	config.WhitelistedPubKeys[other.pk] = struct{}{}
	body2 := []byte("added account's file")
	sum2 := sha256.Sum256(body2)
	sha2 := hex.EncodeToString(sum2[:])
	if got := do(http.MethodPut, "/upload", blossomUploadAuth(t, other.sk, body2), body2); got != 200 {
		t.Fatalf("added account upload: %d", got)
	}
	_ = do(http.MethodDelete, "/"+sha2, deviceBlobAuth(t, phone, "delete", sha2, vault.pk, soon), nil)
	if got := do(http.MethodHead, "/"+sha2, "", nil); got != 200 {
		t.Errorf("another account's blob after a device delete: %d, want 200 (kept)", got)
	}
}

// A device key may only do Blossom upload, get and delete.
func TestDeviceKeyRefusedElsewhere(t *testing.T) {
	vault, phone := newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)
	req := httptest.NewRequest(http.MethodGet, "/list/"+phone.pk, nil)
	req.Header.Set("Authorization", deviceBlobAuth(t, phone, "list", "", vault.pk, time.Now().Add(time.Minute)))
	if _, code, _ := withMeshDeviceAuth(req); code != http.StatusForbidden {
		t.Errorf("device list: %d, want 403", code)
	}
}
