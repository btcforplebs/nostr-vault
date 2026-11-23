//go:build !(js && wasm)

package main

// The rank nudge, and the devices this one copies from.
//
// A Haven that has just ranked (trust_rank_job.go logs copyRankBuiltMarker)
// has its app tell the own devices that copy from it: POST /copy/v2/nudge,
// a kind 27235 signed by the Haven's own mesh key with p naming the device,
// like the start (copyv2_server.go). The account key is never used. The
// nudge carries nothing: the device's engine logs copyNudgeMarker, and its
// app turns that into a catch-up, which brings the result over the copy
// token as before (copyv2_trust.go). A phone that misses the nudge (asleep,
// off the mesh) gets it from its hourly check.
//
// copyHeldPeers lets an app relearn the devices it copied from: a first copy
// whose done line the apps could not read (before 2026-11-23) left the app
// thinking no copy had finished, so it never caught up with that device.

import (
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr/nip19"
)

const (
	// copyRankBuiltMarker: this Haven has a new trust rank result. Its app
	// nudges the own devices on it.
	copyRankBuiltMarker = "RANK_BUILT"
	// copyNudgeMarker: a paired device this one copies from has a new
	// result (`RANK_READY peer=<npub>`). The app catches up with it.
	copyNudgeMarker = "RANK_READY"
	// copyDoneMark: copy_sync.json's key suffix for "a first copy from this
	// peer finished", kept even when it left files out (the main mark is
	// cleared then, so the first catch-up compares everything).
	copyDoneMark = "#done"
	// copyNudgeEvery: at most one RANK_READY line per peer this often.
	copyNudgeEvery = time.Minute
)

var (
	copyNudgeMu   sync.Mutex
	copyNudgeLast = map[string]time.Time{}
)

// nudge is POST /copy/v2/nudge. 204 once the line is logged (or was, in the
// last copyNudgeEvery); 404 from a device this one does not copy from.
func (s *copyServer) nudge(w http.ResponseWriter, r *http.Request) {
	now := s.now()
	ev, code, why := copySignedPost(r, "/copy/v2/nudge", now)
	if code != 0 {
		http.Error(w, why, code)
		return
	}
	peer := strings.ToLower(ev.PubKey)
	// Only a paired device's own mesh key, naming this device.
	if !meshDevices.paired(peer) {
		http.Error(w, "only the owner's paired devices may nudge", http.StatusForbidden)
		return
	}
	if meshKeyHex(tagValueOf(ev.Tags, "p")) != meshDevices.selfKey() {
		http.Error(w, "authorization is for another vault", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	fresh := s.spendAuth(ev.ID, now)
	s.mu.Unlock()
	if !fresh {
		http.Error(w, "authorization was already used", http.StatusUnauthorized)
		return
	}
	npub, held := copyHolds(peer)
	if !held {
		http.NotFound(w, r)
		return
	}
	copyNudgeMu.Lock()
	due := now.Sub(copyNudgeLast[peer]) >= copyNudgeEvery
	if due {
		copyNudgeLast[peer] = now
	}
	copyNudgeMu.Unlock()
	if due {
		log.Printf("%s peer=%s", copyNudgeMarker, npub)
	}
	w.WriteHeader(http.StatusNoContent)
}

// copyHolds: whether this device copied from the mesh key peer (hex): it
// holds a copy token from it and a first copy finished (copyDoneMark), or a
// catch-up did (the main mark), or its copy folder is gone. Returns
// the npub the app names it by.
func copyHolds(peer string) (string, bool) {
	npub, err := nip19.EncodePublicKey(peer)
	if err != nil {
		return "", false
	}
	copyPeersMu.Lock()
	tokens := loadCopyPeers()
	copyPeersMu.Unlock()
	copySyncMu.Lock()
	marks := loadCopySync()
	copySyncMu.Unlock()
	for _, name := range []string{npub, peer} {
		key := copyPeerKey(name)
		if tokens[key] == "" {
			continue
		}
		if marks[key] > 0 || marks[copyPeerKey(name+copyDoneMark)] > 0 {
			return npub, true
		}
		// A first copy from before the done mark that left files out has
		// neither mark. run() makes the copy folder before it asks for the
		// token and removes it only once the copy is in, so a token with no
		// folder is a finished copy (Tron, #2476).
		if _, err := os.Stat(filepath.Join(copyInDir, key)); errors.Is(err, os.ErrNotExist) {
			return npub, true
		}
	}
	return "", false
}

// copyHeldPeers: the paired devices this one copied from, as sorted npubs.
func copyHeldPeers() []string {
	out := []string{}
	for _, hex := range meshDevices.pairedKeys() {
		if npub, ok := copyHolds(hex); ok {
			out = append(out, npub)
		}
	}
	sort.Strings(out)
	return out
}

// pairedKeys: the paired devices' mesh keys (hex).
func (m *meshDeviceSet) pairedKeys() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]string, 0, len(m.devices))
	for hex := range m.devices {
		if hex != m.self {
			out = append(out, hex)
		}
	}
	return out
}
