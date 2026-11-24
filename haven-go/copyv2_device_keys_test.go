package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Fail closed (Logen, 2026-11-19): the account key never starts a copy, only a
// paired device's mesh key does. These helpers give a copy test paired
// devices on this vault, one per label the test names a device by (hex or
// npub of the same label is the same device). All keys are throwaway.
type copyTestDeviceSet struct {
	self  testKey
	keys  map[string]testKey
	order []testKey
}

var copyDevices *copyTestDeviceSet

func copyDeviceKey(t *testing.T, label string) testKey {
	t.Helper()
	if prefix, pk, err := nip19.Decode(label); err == nil && prefix == "npub" {
		label, _ = pk.(string)
	}
	label = strings.ToLower(label)
	if copyDevices == nil {
		copyDevices = &copyTestDeviceSet{self: newTestKey(t), keys: map[string]testKey{}}
		prev := meshDevices
		meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
		t.Cleanup(func() { meshDevices, copyDevices = prev, nil })
	}
	if k, ok := copyDevices.keys[label]; ok {
		return k
	}
	k := newTestKey(t)
	copyDevices.keys[label] = k
	copyDevices.order = append(copyDevices.order, k)
	if err := meshDevices.set(meshSetJSON(t, copyDevices.self, copyDevices.order...)); err != nil {
		t.Fatal(err)
	}
	return k
}

// copyDeviceProof: the start proof of the device named label, in the device
// form (its own mesh key, p = this vault).
func copyDeviceProof(t *testing.T, label string, at nostr.Timestamp, path string) string {
	t.Helper()
	dev := copyDeviceKey(t, label)
	tags := nostr.Tags{{"u", "http://127.0.0.1:9/" + strings.TrimPrefix(path, "/")}, {"method", "POST"}, {"p", copyDevices.self.pk}}
	// A fresh content keeps two proofs in one second distinct (each id is taken once).
	ev := dev.sign(t, nostr.Event{Kind: 27235, CreatedAt: at, Tags: tags, Content: nostr.GeneratePrivateKey()})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

// accountStartProof: a start proof signed by k itself naming device, the
// account-key form the vault now refuses.
func accountStartProof(t *testing.T, k testKey, device string) string {
	t.Helper()
	tags := nostr.Tags{{"u", "http://127.0.0.1:9/copy/v2/start"}, {"method", "POST"}}
	if device != "" {
		tags = append(tags, nostr.Tag{"device", device})
	}
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: tags})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

func TestCopyStartRefusesTheAccountKey(t *testing.T) {
	owner := newTestKey(t)
	openCopyVault(t, owner.pk)
	s := newTestCopyServer(failingBuild)
	copyDeviceKey(t, testDevice) // a paired device exists; the account still may not start
	for _, device := range []string{testDevice, ""} {
		if code, _, _ := startAs(t, s, accountStartProof(t, owner, device)); code != 403 {
			t.Errorf("account-signed start naming %q: %d, want 403", device, code)
		}
	}
	if code, _, _ := startAs(t, s, copyDeviceProof(t, testDevice, nostr.Now(), "/copy/v2/start")); code != 200 {
		t.Errorf("the paired device's start: %d, want 200", code)
	}
}
