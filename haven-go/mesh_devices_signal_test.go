package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Tim, #1803: a vault with a paired set marks its mesh Blossom refusals, so
// the app does not fall back to the account key there.
func TestMeshDoorRefusalSaysTheSetExists(t *testing.T) {
	vault, phone, stranger := newTestKey(t), newTestKey(t), newTestKey(t)
	sha := strings.Repeat("ab", 32)
	upload := func() *httptest.ResponseRecorder {
		t.Helper()
		req := markMesh(httptest.NewRequest(http.MethodHead, "/upload", nil))
		req.Header.Set("X-SHA-256", sha)
		req.Header.Set("Authorization", deviceBlobAuth(t, stranger, "upload", sha, vault.pk, time.Now().Add(time.Minute)))
		rec := httptest.NewRecorder()
		meshHandler(rec, req)
		return rec
	}

	// No set yet (older app, or not given it): refused, no header, so the
	// app keeps its owner fallback.
	meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}
	rec := upload()
	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("no set: %d, want 401/403", rec.Code)
	}
	if got := rec.Header().Get(meshDevicesHeader); got != "" {
		t.Errorf("no set: header %q, want none", got)
	}

	// With a set that does not hold this key: the same refusal, marked.
	pairMeshDevices(t, vault, phone)
	rec = upload()
	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("set: %d, want 401/403", rec.Code)
	}
	if got := rec.Header().Get(meshDevicesHeader); got != "set" {
		t.Errorf("set: header %q, want \"set\"", got)
	}
}

// The header goes only on a mesh Blossom 401/403: not off the mesh (the
// public URL does not learn about the set, and a device key never works
// there), not on websockets (no wrapper, Hijack intact), not on other codes.
func TestMeshDevicesSignalScope(t *testing.T) {
	vault, phone := newTestKey(t), newTestKey(t)
	pairMeshDevices(t, vault, phone)
	sha := strings.Repeat("cd", 32)
	refuse := func(r *http.Request, code int) string {
		t.Helper()
		rec := httptest.NewRecorder()
		w := withMeshDevicesSignal(rec, r)
		http.Error(w, "no", code)
		return rec.Header().Get(meshDevicesHeader)
	}
	lan := httptest.NewRequest(http.MethodDelete, "/"+sha, nil)
	lan.RemoteAddr = "192.168.1.20:5555"
	if got := refuse(lan, 403); got != "" {
		t.Errorf("LAN: %q, want none", got)
	}
	tunnel := httptest.NewRequest(http.MethodDelete, "/"+sha, nil)
	tunnel.RemoteAddr = "127.0.0.1:4000"
	tunnel.Header.Set("Cf-Ray", "abc")
	if got := refuse(tunnel, 401); got != "" {
		t.Errorf("Cloudflare tunnel: %q, want none", got)
	}
	ws := markMesh(httptest.NewRequest(http.MethodGet, "/", nil))
	rec := httptest.NewRecorder()
	if w := withMeshDevicesSignal(rec, ws); w != http.ResponseWriter(rec) {
		t.Error("websocket request was wrapped")
	}
	door := func() *http.Request { return markMesh(httptest.NewRequest(http.MethodDelete, "/"+sha, nil)) }
	if got := refuse(door(), 403); got != "set" {
		t.Errorf("door 403: %q, want set", got)
	}
	if got := refuse(door(), 401); got != "set" {
		t.Errorf("door 401: %q, want set", got)
	}
	if got := refuse(door(), 409); got != "" {
		t.Errorf("door 409: %q, want none", got)
	}
	loop := httptest.NewRequest(http.MethodPut, "/upload", nil)
	loop.RemoteAddr = "127.0.0.1:4000"
	if got := refuse(loop, 401); got != "set" {
		t.Errorf("relay port over loopback: %q, want set", got)
	}
}
