//go:build !(js && wasm)

package main

// Mesh vault copy v2, A's side: /copy/v2/* (docs/MESH_COPY_V2_CONTRACT.md §1-§3).
// Mounted on the relay handler the owner's own devices reach over the mesh,
// never on the door (meshHandler has no /copy route).

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

const (
	copyAuthKind   = 27235
	copyAuthWindow = 60 * time.Second
	// copyTokenIdle: a copy token unused this long stops working.
	copyTokenIdle  = 30 * 24 * time.Hour
	copyTokensFile = "copy_tokens.json"
)

// copyServer holds A's copies and tokens. One per process.
type copyServer struct {
	mu     sync.Mutex
	jobs   map[string]*copyJob
	seen   map[string]time.Time // NIP-98 ids accepted, for one use each
	tokens []copyToken
	loaded bool
	now    func() time.Time
	// syncDB: the store the catch-up reads and writes; copySyncDB unless a test sets it.
	syncDB func(string) DBBackend
	// cacheDir: where copies are built; copyCacheDir unless a test sets it.
	cacheDir string
	// build is buildCopy, swapped in tests.
	build func(dir, id string, progress copyBuildProgress) (copyManifest, error)
}

type copyJob struct {
	manifest copyManifest
	dir      string
	token    string // sha256 of the bearer that may read it
	built    time.Time
}

// copyToken: a B that may read copies and sync (only its hash is kept).
type copyToken struct {
	Hash  string `json:"hash"`
	Owner string `json:"owner"`
	// Device: B's mesh pubkey (hex), named in the owner's start proof.
	Device   string `json:"device"`
	Created  int64  `json:"created"`
	LastUsed int64  `json:"last_used"`
}

var copyV2 = &copyServer{jobs: map[string]*copyJob{}, seen: map[string]time.Time{}, now: time.Now}

// Unpair on A: a device that leaves the paired set loses its tokens at once.
func init() { onMeshDeviceUnpaired = func(hex string) { copyV2.revoke(hex) } }

func (s *copyServer) loadTokens() {
	if s.loaded {
		return
	}
	s.loaded = true
	if raw, err := os.ReadFile(copyTokensFile); err == nil {
		_ = json.Unmarshal(raw, &s.tokens)
	}
}

func (s *copyServer) saveTokens() {
	raw, _ := json.Marshal(s.tokens)
	tmp := copyTokensFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copyTokensFile)
	}
}

func copyHashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func copyRandomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// bearer: the token hash a request carries, when it is live for this owner.
func (s *copyServer) bearer(r *http.Request) (string, bool) {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || len(strings.TrimSpace(raw)) != 64 {
		return "", false
	}
	h := copyHashToken(strings.TrimSpace(raw))
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loadTokens()
	now := s.now()
	for i := range s.tokens {
		t := &s.tokens[i]
		if t.Hash != h {
			continue
		}
		if t.Owner != config.OwnerPubKey || now.Sub(time.Unix(t.LastUsed, 0)) > copyTokenIdle {
			return "", false
		}
		// Saved at most hourly: every chunk request would otherwise write the file.
		if now.Sub(time.Unix(t.LastUsed, 0)) > time.Hour {
			t.LastUsed = now.Unix()
			s.saveTokens()
		}
		return h, true
	}
	return "", false
}

// copyDevice reads the start proof's ["device", <B's mesh npub or hex>].
func copyDevice(tags nostr.Tags) string {
	v := strings.TrimSpace(tagValueOf(tags, "device"))
	if strings.HasPrefix(v, "npub1") {
		if prefix, pk, err := nip19.Decode(v); err == nil && prefix == "npub" {
			v, _ = pk.(string)
		}
	}
	v = strings.ToLower(v)
	if !copyIsHex(v, 64) {
		return ""
	}
	return v
}

// copyIsHex: s is exactly n lowercase hex digits.
func copyIsHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// checkStart verifies the NIP-98 proof for POST /copy/v2/start: signed by a
// paired device's own mesh key (the device form), or, until the apps switch,
// by the owner. The u tag's path must be /copy/v2/start; its host is not
// compared (A and B name the same mesh link by different loopback
// addresses). 401 for no, bad, stale or replayed proof; 403 for a good proof
// by a key that is neither. Returns the device the token is bound to.
func (s *copyServer) checkStart(r *http.Request) (int, string, string) {
	header, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Nostr ")
	if !ok {
		return http.StatusUnauthorized, "missing Authorization: Nostr header", ""
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(header))
	if err != nil {
		return http.StatusUnauthorized, "authorization is not base64", ""
	}
	var ev nostr.Event
	if err := json.Unmarshal(raw, &ev); err != nil || ev.Kind != copyAuthKind {
		return http.StatusUnauthorized, "authorization is not a kind 27235 event", ""
	}
	now := s.now()
	if at := ev.CreatedAt.Time(); at.Before(now.Add(-copyAuthWindow)) || at.After(now.Add(copyAuthWindow)) {
		return http.StatusUnauthorized, "authorization is outside the 60 s window", ""
	}
	if !ev.CheckID() {
		return http.StatusUnauthorized, "authorization id does not match its content", ""
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return http.StatusUnauthorized, "authorization signature is invalid", ""
	}
	if !strings.EqualFold(tagValueOf(ev.Tags, "method"), http.MethodPost) {
		return http.StatusUnauthorized, "authorization is not for POST", ""
	}
	u, err := url.Parse(tagValueOf(ev.Tags, "u"))
	if err != nil || !u.IsAbs() || u.Path != "/copy/v2/start" || u.RawQuery != "" {
		return http.StatusUnauthorized, "authorization is not for /copy/v2/start", ""
	}
	var device string
	switch {
	case meshDevices.paired(strings.ToLower(ev.PubKey)):
		// The device form (§2): B signs with its own mesh key, A's paired
		// set names it, and the p tag names A, so the proof cannot be
		// replayed against another of the owner's vaults.
		device = strings.ToLower(ev.PubKey)
		if meshKeyHex(tagValueOf(ev.Tags, "p")) != meshDevices.selfKey() {
			return http.StatusUnauthorized, "authorization is for another vault", ""
		}
		if named := tagValueOf(ev.Tags, "device"); named != "" && copyDevice(ev.Tags) != device {
			return http.StatusUnauthorized, "authorization names another device", ""
		}
	case config.OwnerPubKey != "" && strings.EqualFold(ev.PubKey, config.OwnerPubKey):
		// The owner-key form. TODO(mesh-key): remove once every app signs the
		// start with its device key (docs/MESH_COPY_V2_CONTRACT.md §2).
		device = copyDevice(ev.Tags)
		if device == "" {
			return http.StatusUnauthorized, "authorization names no device", ""
		}
	default:
		return http.StatusForbidden, "only the owner's paired devices may copy this vault", ""
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, t := range s.seen {
		if now.Sub(t) > 2*copyAuthWindow {
			delete(s.seen, id)
		}
	}
	if _, dup := s.seen[ev.ID]; dup {
		return http.StatusUnauthorized, "authorization was already used", ""
	}
	s.seen[ev.ID] = now
	return 0, "", device
}

func tagValueOf(tags nostr.Tags, name string) string {
	for _, t := range tags {
		if len(t) >= 2 && t[0] == name {
			return t[1]
		}
	}
	return ""
}

// sweep deletes copies past copyKeepFor, in memory and on disk (a copy left
// by an earlier run too).
func (s *copyServer) cache() string {
	if s.cacheDir != "" {
		return s.cacheDir
	}
	return copyCacheDir
}

func (s *copyServer) sweep() {
	now := s.now()
	for id, j := range s.jobs {
		if now.Sub(j.built) > copyKeepFor {
			_ = os.RemoveAll(j.dir)
			delete(s.jobs, id)
		}
	}
	// A directory with no job here was left by an earlier run: no token can
	// read it any more, so it only holds disk.
	entries, _ := os.ReadDir(s.cache())
	for _, e := range entries {
		if _, live := s.jobs[e.Name()]; !live {
			_ = os.RemoveAll(filepath.Join(s.cache(), e.Name()))
		}
	}
}

func copyJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// copyThroughTunnel: a request a public tunnel forwarded (Cloudflare names
// the client). The mesh hands the own devices this port on loopback with no
// such header; a copy never runs over the open internet.
func copyThroughTunnel(r *http.Request) bool {
	return r.Header.Get("Cf-Connecting-Ip") != "" || r.Header.Get("Cf-Ray") != ""
}

// copyFromLoopback: the request came from this machine, which is how the mesh
// hands the own devices this port (and the iPhone's own port). Mac, Android
// and the box also listen on the LAN (RELAY_BIND_ADDRESS 0.0.0.0), and a
// removed device there must not reach the copy. The box's havend forwards to
// the engine over loopback but names the real client in X-Forwarded-For, so
// every hop it names must be loopback too.
func copyFromLoopback(r *http.Request) bool {
	if !copyLoopbackAddr(r.RemoteAddr) {
		return false
	}
	if r.Header.Get("Forwarded") != "" {
		return false
	}
	for _, v := range append(r.Header.Values("X-Forwarded-For"), r.Header.Values("X-Real-Ip")...) {
		for _, hop := range strings.Split(v, ",") {
			if !copyLoopbackAddr(strings.TrimSpace(hop)) {
				return false
			}
		}
	}
	return true
}

func copyLoopbackAddr(a string) bool {
	if host, _, err := net.SplitHostPort(a); err == nil {
		a = host
	}
	ip, err := netip.ParseAddr(strings.Trim(a, "[]"))
	return err == nil && ip.Unmap().IsLoopback()
}

// revoke drops every token for device (B's mesh npub or hex) and the copies
// they could read: Remove device. Reports whether any was held.
func (s *copyServer) revoke(device string) bool {
	device = copyDevice(nostr.Tags{{"device", device}})
	if device == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loadTokens()
	return s.dropDevice(device)
}

// dropDevice removes device's tokens and their copies. Caller holds s.mu.
func (s *copyServer) dropDevice(device string) bool {
	gone := map[string]bool{}
	kept := s.tokens[:0]
	for _, t := range s.tokens {
		if t.Device == device {
			gone[t.Hash] = true
			continue
		}
		kept = append(kept, t)
	}
	s.tokens = kept
	if len(gone) == 0 {
		return false
	}
	s.saveTokens()
	for id, j := range s.jobs {
		if gone[j.token] {
			_ = os.RemoveAll(j.dir)
			delete(s.jobs, id)
		}
	}
	return true
}

// ServeHTTP is /copy/v2/*.
func (s *copyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if copyThroughTunnel(r) || !copyFromLoopback(r) {
		http.NotFound(w, r)
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/copy/v2/")
	switch {
	case rest == "start" && r.Method == http.MethodPost:
		s.start(w, r)
	case strings.HasPrefix(rest, "sync/"):
		s.serveSync(w, r, strings.TrimPrefix(rest, "sync/"))
	default:
		id, sub, _ := strings.Cut(rest, "/")
		s.serveCopy(w, r, id, sub)
	}
}

func (s *copyServer) start(w http.ResponseWriter, r *http.Request) {
	code, why, device := s.checkStart(r)
	if code != 0 {
		http.Error(w, why, code)
		return
	}
	token := copyRandomHex(32)
	id := copyRandomHex(16)
	th := copyHashToken(token)
	s.mu.Lock()
	s.loadTokens()
	s.sweep()
	now := s.now()
	// One token per B: a new start replaces that device's old token (and the
	// copy it could read). Tokens idle for 30 days, from an old owner or
	// from before tokens named their device fall away here.
	s.dropDevice(device)
	kept := s.tokens[:0]
	for _, t := range s.tokens {
		if now.Sub(time.Unix(t.LastUsed, 0)) <= copyTokenIdle && t.Owner == config.OwnerPubKey && t.Device != "" {
			kept = append(kept, t)
		}
	}
	s.tokens = append(kept, copyToken{Hash: th, Owner: config.OwnerPubKey, Device: device, Created: now.Unix(), LastUsed: now.Unix()})
	s.saveTokens()
	dir := filepath.Join(s.cache(), id)
	job := &copyJob{manifest: copyManifest{V: 2, ID: id, State: "building", Owner: config.OwnerPubKey, CreatedAt: now.Unix()}, dir: dir, token: th, built: now}
	s.jobs[id] = job
	building := false
	for _, j := range s.jobs {
		if j != job && j.manifest.State == "building" {
			building = true
		}
	}
	s.mu.Unlock()
	if building {
		// One build at a time: two would need twice the disk.
		s.fail(job, "busy")
	} else {
		go s.runBuild(job)
	}
	copyJSON(w, http.StatusOK, map[string]string{"id": id, "token": token, "state": "building"})
}

func (s *copyServer) fail(job *copyJob, code string) {
	s.mu.Lock()
	job.manifest.State, job.manifest.Error = "failed", code
	s.mu.Unlock()
	_ = os.RemoveAll(job.dir)
}

func (s *copyServer) runBuild(job *copyJob) {
	build := s.build
	if build == nil {
		build = func(dir, id string, p copyBuildProgress) (copyManifest, error) {
			return buildCopy(copyContext(), dir, id, p)
		}
	}
	log.Println(formatCopyLine(copyLine{Stage: "building", Part: "-", Source: "mesh"}))
	m, err := build(job.dir, job.manifest.ID, func(p copyProgress) {
		s.mu.Lock()
		job.manifest.Progress = p
		s.mu.Unlock()
	})
	if err != nil {
		code := "build_failed"
		if errors.Is(err, errCopyNoSpace) {
			code = "no_space"
		}
		slog.Error("copy build failed", "id", job.manifest.ID, "error", err)
		s.fail(job, code)
		return
	}
	s.mu.Lock()
	m.Progress = job.manifest.Progress
	job.manifest = m
	job.built = s.now()
	s.mu.Unlock()
	slog.Info("copy built", "id", m.ID, "parts", len(m.Parts), "files", m.Files.Count)
}

func (s *copyServer) serveCopy(w http.ResponseWriter, r *http.Request, id, sub string) {
	th, ok := s.bearer(r)
	if !ok {
		http.Error(w, "auth_refused", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	s.sweep()
	job := s.jobs[id]
	if job == nil || job.token != th {
		s.mu.Unlock()
		http.Error(w, "not_found", http.StatusNotFound)
		return
	}
	m := job.manifest
	s.mu.Unlock()
	switch {
	case sub == "" && r.Method == http.MethodGet:
		copyJSON(w, http.StatusOK, m)
	case sub == "done" && r.Method == http.MethodPost:
		s.mu.Lock()
		delete(s.jobs, id)
		s.mu.Unlock()
		_ = os.RemoveAll(job.dir)
		copyJSON(w, http.StatusOK, map[string]string{"state": "deleted"})
	case (sub == "notes" || sub == "media") && r.Method == http.MethodGet:
		if m.State != "ready" {
			http.Error(w, "building", http.StatusConflict)
			return
		}
		s.serveChunk(w, r, job, m, sub)
	default:
		http.NotFound(w, r)
	}
}

// serveChunk answers one whole chunk: Range must be exactly chunk i's bytes.
func (s *copyServer) serveChunk(w http.ResponseWriter, r *http.Request, job *copyJob, m copyManifest, name string) {
	var part *copyPart
	for i := range m.Parts {
		if m.Parts[i].Name == name {
			part = &m.Parts[i]
		}
	}
	if part == nil {
		http.NotFound(w, r)
		return
	}
	a, b, ok := copyRange(r.Header.Get("Range"))
	if !ok || a%copyChunkSize != 0 || a >= part.Size || b != min(a+copyChunkSize, part.Size)-1 {
		w.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(part.Size, 10))
		http.Error(w, "range", http.StatusRequestedRangeNotSatisfiable)
		return
	}
	f, err := os.Open(filepath.Join(job.dir, name+".zip"))
	if err != nil {
		http.Error(w, "not_found", http.StatusNotFound)
		return
	}
	defer f.Close()
	buf := make([]byte, b-a+1)
	if _, err := f.ReadAt(buf, a); err != nil {
		http.Error(w, "read failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", a, b, part.Size))
	w.Header().Set("Content-Length", strconv.Itoa(len(buf)))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = w.Write(buf)
}

// copyRange reads "bytes=a-b".
func copyRange(h string) (int64, int64, bool) {
	spec, ok := strings.CutPrefix(h, "bytes=")
	if !ok {
		return 0, 0, false
	}
	x, y, ok := strings.Cut(spec, "-")
	a, err1 := strconv.ParseInt(x, 10, 64)
	b, err2 := strconv.ParseInt(y, 10, 64)
	return a, b, ok && err1 == nil && err2 == nil && a >= 0 && b >= a
}

// copyContext: the build's context. Not tied to one request: B polls while it runs.
func copyContext() context.Context { return context.Background() }
