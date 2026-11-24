package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"testing"
	"time"
)

// Over the mesh only a paired device's mesh key signs a Blossom request, never
// the account key (Logen, 2026-11-19: fail closed). The door tests sign as the
// owner's paired phone (copyDeviceKey pairs it on this vault).

// meshDeviceUploadAuth: the paired phone's upload token for body, four minutes.
func meshDeviceUploadAuth(t *testing.T, body []byte) string {
	t.Helper()
	return meshDeviceUploadAuthExp(t, body, time.Now().Add(4*time.Minute)) // a device token lives 5 min at most
}

func meshDeviceUploadAuthExp(t *testing.T, body []byte, exp time.Time) string {
	t.Helper()
	sum := sha256.Sum256(body)
	return meshDeviceBlobAuth(t, "upload", hex.EncodeToString(sum[:]), exp)
}

// meshDeviceBlobAuth: the paired phone's token for verb on sha.
func meshDeviceBlobAuth(t *testing.T, verb, sha string, exp time.Time) string {
	t.Helper()
	phone := copyDeviceKey(t, "phone")
	return deviceBlobAuth(t, phone, verb, sha, copyDevices.self.pk, exp)
}

func TestMeshDoorRefusesTheAccountKey(t *testing.T) {
	h := startHaven(t)
	door := startMeshDoor(t)
	body := []byte("signed by the account, not the phone")
	copyDeviceKey(t, "phone") // a paired set exists; the account is still refused
	if code := meshPut(t, door, blossomUploadAuth(t, h.ownerSK, body), body); code != http.StatusForbidden {
		t.Fatalf("account-signed upload over the mesh: %d, want 403", code)
	}
	if code := meshPut(t, door, meshDeviceUploadAuth(t, body), body); code != http.StatusOK {
		t.Fatalf("the paired phone's upload: %d, want 200", code)
	}
}
