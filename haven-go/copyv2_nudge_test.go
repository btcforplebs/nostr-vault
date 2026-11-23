//go:build !(js && wasm)

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// All keys are throwaway; the mesh never uses the account key.

func nudgeProof(t *testing.T, k testKey, p string, at nostr.Timestamp, path string) string {
	t.Helper()
	ev := k.sign(t, nostr.Event{Kind: 27235, CreatedAt: at, Tags: nostr.Tags{
		{"u", "http://127.0.0.1:9" + path}, {"method", "POST"}, {"p", p},
	}})
	raw, _ := json.Marshal(ev)
	return base64.StdEncoding.EncodeToString(raw)
}

func nudgeAs(s *copyServer, auth string) int {
	req := copyReq(http.MethodPost, "/copy/v2/nudge", nil)
	if auth != "" {
		req.Header.Set("Authorization", "Nostr "+auth)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec.Code
}

// The first copy's done line must parse like every other COPY line: the
// apps refused one with an empty part and source, so a phone never knew
// its first copy finished and never caught up (LogePhone, 2026-11-23).
func TestCopyDoneLineParses(t *testing.T) {
	done := copyLine{Stage: "done", Part: "-", Source: "mesh", Items: [2]int64{5, 5}}
	line := formatCopyLine(done) + " notes=5 messages=0 files=0 left_out=0 not_caught_up="
	got, ok := parseCopyLine("2026/11/23 10:54:52 " + line)
	if !ok || got.Stage != "done" {
		t.Fatalf("done line refused: %q", line)
	}
}

func TestCopyNudgeOnlyFromAPairedDeviceThisOneCopiedFrom(t *testing.T) {
	owner, self, mac, stranger := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, self, mac)
	copyNudgeMu.Lock()
	copyNudgeLast = map[string]time.Time{}
	copyNudgeMu.Unlock()
	var logs bytes.Buffer
	captureLog(t, &logs)
	s := newTestCopyServer(nil)
	me := meshNpub(self.pk)

	// Paired, but nothing copied from the Mac yet.
	if got := nudgeAs(s, nudgeProof(t, mac, me, nostr.Now(), "/copy/v2/nudge")); got != 404 {
		t.Fatalf("before any copy: %d, want 404", got)
	}
	saveCopyPeerToken(meshNpub(mac.pk), strings.Repeat("ab", 32))
	markCopySynced(meshNpub(mac.pk), time.Now().Unix())

	cases := []struct {
		name string
		auth string
		want int
	}{
		{"no proof", "", 401},
		{"stale", nudgeProof(t, mac, me, nostr.Now()-120, "/copy/v2/nudge"), 401},
		{"for the start", nudgeProof(t, mac, me, nostr.Now(), "/copy/v2/start"), 401},
		{"a stranger", nudgeProof(t, stranger, me, nostr.Now(), "/copy/v2/nudge"), 403},
		{"for another vault", nudgeProof(t, mac, meshNpub(stranger.pk), nostr.Now(), "/copy/v2/nudge"), 401},
		{"the owner's account key", nudgeProof(t, owner, me, nostr.Now(), "/copy/v2/nudge"), 403},
	}
	for _, c := range cases {
		if got := nudgeAs(s, c.auth); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
	if strings.Contains(logs.String(), copyNudgeMarker) {
		t.Fatalf("a refused nudge logged a line:\n%s", logs.String())
	}
	// A second earlier than the 404 probe, so not the same id.
	good := nudgeProof(t, mac, me, nostr.Now()-1, "/copy/v2/nudge")
	if got := nudgeAs(s, good); got != 204 {
		t.Fatalf("the Mac's nudge: %d, want 204", got)
	}
	if got := nudgeAs(s, good); got != 401 {
		t.Errorf("the same proof again: %d, want 401", got)
	}
	want := copyNudgeMarker + " peer=" + meshNpub(mac.pk)
	if strings.Count(logs.String(), want) != 1 {
		t.Fatalf("want one %q line:\n%s", want, logs.String())
	}
	// A second nudge inside a minute: answered, not logged again.
	if got := nudgeAs(s, nudgeProof(t, mac, me, nostr.Now()-2, "/copy/v2/nudge")); got != 204 {
		t.Fatalf("second nudge: %d, want 204", got)
	}
	if strings.Count(logs.String(), want) != 1 {
		t.Fatalf("second nudge inside a minute logged again:\n%s", logs.String())
	}
}

func TestCopyHeldPeersNamesOnlyCopiedPairedDevices(t *testing.T) {
	owner, self, mac, pad, gone, box := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	openCopyVault(t, owner.pk)
	pairMeshDevices(t, self, mac, pad, box)
	// The box: a finished first copy that left a file out, so only its done
	// mark is set (Tron #2476).
	saveCopyPeerToken(meshNpub(box.pk), strings.Repeat("12", 32))
	markCopySynced(meshNpub(box.pk)+copyDoneMark, time.Now().Unix())
	// The Mac: token and a finished first copy. The iPad: a token only (a
	// copy still under way). gone: copied from, but no longer paired.
	saveCopyPeerToken(meshNpub(mac.pk), strings.Repeat("ab", 32))
	markCopySynced(meshNpub(mac.pk), time.Now().Unix())
	saveCopyPeerToken(meshNpub(pad.pk), strings.Repeat("cd", 32))
	saveCopyPeerToken(meshNpub(gone.pk), strings.Repeat("ef", 32))
	markCopySynced(meshNpub(gone.pk), time.Now().Unix())
	got := copyHeldPeers()
	want := []string{meshNpub(mac.pk), meshNpub(box.pk)}
	sort.Strings(want)
	if !slices.Equal(got, want) {
		t.Fatalf("held peers %v, want the Mac and the box", got)
	}
}

// lastLineWith: the last log line holding s ("" when none).
func lastLineWith(logs, s string) string {
	out := ""
	for _, l := range strings.Split(logs, "\n") {
		if strings.Contains(l, s) {
			out = l
		}
	}
	return out
}

func meshNpub(pk string) string { n, _ := nip19.EncodePublicKey(pk); return n }
