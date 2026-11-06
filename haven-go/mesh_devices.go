package main

// The mesh never uses the account key (Logen, 2026-11-06). The owner's own
// devices prove who they are with their own mesh key, and this vault accepts
// one only when the app has told it that key is a paired device of this
// owner. Contract: docs/MESH_COPY_V2_CONTRACT.md §2 (copy start) and §2.1
// (Blossom over the mesh).
//
// The app passes the set at start and on every change (SetMeshDevicesC), the
// same way it passes own_devices to FIPS: the owner's devices only, roles
// kept. An empty or missing set accepts no device: there is no fallback to
// "anyone".

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

const (
	// meshDeviceAuthMaxAhead: a device's kind 24242 may expire at most this
	// far ahead. Device tokens are signed per request, so a short life costs
	// nothing and bounds a leaked one.
	meshDeviceAuthMaxAhead = 5 * time.Minute
)

// meshDeviceSet is this vault's own mesh key and its paired devices (hex).
type meshDeviceSet struct {
	mu      sync.RWMutex
	self    string
	devices map[string]string // hex -> role
	// seen: device 24242 ids already used -> expiration (unix), for one use each.
	seen map[string]int64
	now  func() time.Time
}

var meshDevices = &meshDeviceSet{devices: map[string]string{}, seen: map[string]int64{}, now: time.Now}

// onMeshDeviceUnpaired runs for each device that leaves the set: its copy
// tokens are revoked at once (copyv2_server.go sets it).
var onMeshDeviceUnpaired func(hex string)

// meshKeyHex: a mesh key as 64 lower-case hex, from npub or hex; "" if neither.
func meshKeyHex(v string) string {
	v = strings.TrimSpace(v)
	if strings.HasPrefix(v, "npub1") {
		prefix, pk, err := nip19.Decode(v)
		if err != nil || prefix != "npub" {
			return ""
		}
		v, _ = pk.(string)
	}
	v = strings.ToLower(v)
	if len(v) != 64 {
		return ""
	}
	for _, c := range v {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return ""
		}
	}
	return v
}

// meshDevicesInput is what SetMeshDevicesC takes:
//
//	{"self": "<this vault's mesh npub>", "devices": [{"npub": "…", "role": "phone"}, …]}
type meshDevicesInput struct {
	Self    string `json:"self"`
	Devices []struct {
		Npub string `json:"npub"`
		Role string `json:"role"`
	} `json:"devices"`
}

// set replaces the paired set from the app's JSON. A device that was in the
// old set and is not in the new one is unpaired: its tokens go at once.
func (m *meshDeviceSet) set(raw string) error {
	var in meshDevicesInput
	if err := json.Unmarshal([]byte(raw), &in); err != nil {
		return errors.New("mesh devices: not JSON")
	}
	self := meshKeyHex(in.Self)
	if self == "" && len(in.Devices) > 0 {
		return errors.New("mesh devices: self is not a mesh npub")
	}
	next := map[string]string{}
	for _, d := range in.Devices {
		hex := meshKeyHex(d.Npub)
		if hex == "" {
			return errors.New("mesh devices: a device is not a mesh npub")
		}
		if hex == self {
			continue // this vault is never its own paired device
		}
		next[hex] = d.Role
	}
	m.mu.Lock()
	var gone []string
	for hex := range m.devices {
		if _, kept := next[hex]; !kept {
			gone = append(gone, hex)
		}
	}
	m.self, m.devices = self, next
	m.mu.Unlock()
	for _, hex := range gone {
		if onMeshDeviceUnpaired != nil {
			onMeshDeviceUnpaired(hex)
		}
	}
	return nil
}

// selfKey: this vault's mesh key (hex), "" before the app set it.
func (m *meshDeviceSet) selfKey() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.self
}

// paired: pk is a paired device of this vault, and not the vault itself.
func (m *meshDeviceSet) paired(pk string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.self == "" || pk == m.self {
		return false
	}
	_, ok := m.devices[pk]
	return ok
}

// spend records a device 24242 id as used until it expires; false if it was.
func (m *meshDeviceSet) spend(id string, exp int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now().Unix()
	for k, e := range m.seen {
		if e <= now {
			delete(m.seen, k)
		}
	}
	if _, used := m.seen[id]; used {
		return false
	}
	m.seen[id] = exp
	return true
}

// checkBlobAuth: ev is a paired device's kind 24242 for verb, made for this
// vault, unexpired and short-lived; sha (when known) is in an x tag. Returns
// an HTTP status and reason, or 0.
func (m *meshDeviceSet) checkBlobAuth(ev *nostr.Event, verb, sha string) (int, string) {
	if ev.Kind != 24242 || !ev.CheckID() {
		return http.StatusUnauthorized, "invalid event"
	}
	if ok, _ := ev.CheckSignature(); !ok {
		return http.StatusUnauthorized, "invalid signature"
	}
	if !m.paired(ev.PubKey) {
		return http.StatusForbidden, "not a paired device of this vault"
	}
	self := m.selfKey()
	// Each vault checks it is named: delete everywhere may be one event
	// with a p tag per target (contract §2.1).
	named := false
	for _, p := range tagValues(ev.Tags, "p") {
		named = named || (self != "" && meshKeyHex(p) == self)
	}
	if !named {
		return http.StatusForbidden, "authorization is for another vault"
	}
	if ts := tagValues(ev.Tags, "t"); len(ts) != 1 || ts[0] != verb {
		return http.StatusForbidden, "authorization is not for " + verb
	}
	now := m.now()
	exp := authExpiration(ev)
	if exp <= now.Unix() {
		return http.StatusUnauthorized, "authorization expired"
	}
	if exp > now.Add(meshDeviceAuthMaxAhead).Unix() {
		return http.StatusUnauthorized, "authorization lives longer than 5 minutes"
	}
	if ev.CreatedAt.Time().After(now.Add(maxFutureSkew)) {
		return http.StatusUnauthorized, "authorization is from the future"
	}
	if sha != "" && ev.Tags.FindWithValue("x", sha) == nil {
		return http.StatusForbidden, "authorization does not cover this blob"
	}
	return 0, ""
}

func tagValues(tags nostr.Tags, name string) []string {
	var out []string
	for _, t := range tags {
		if len(t) >= 2 && t[0] == name {
			out = append(out, t[1])
		}
	}
	return out
}

type meshDeviceAuthKey struct{}

// meshOwnPortKey marks a request that came in on the iPhone's own-device
// port (HAVEN_MESH_OWN_PORT), which only the mesh reaches.
type meshOwnPortKey struct{}

// markMeshOwnPort wraps the own-device port's handler.
func markMeshOwnPort(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), meshOwnPortKey{}, true)))
	})
}

// meshDeviceOverLoopback: on the relay port, the request came from this
// machine and not through a tunnel, which is how the mesh hands Mac,
// Android and the box's own devices that port (the same gate as /copy/v2,
// copyv2_server.go sets it). Never true where it is not set (wasm).
var meshDeviceOverLoopback = func(*http.Request) bool { return false }

// meshDeviceOverMesh: r came in over the mesh: the door, the iPhone's own
// port, or the relay port from loopback with no tunnel or LAN hop named.
func meshDeviceOverMesh(r *http.Request) bool {
	return isMeshRequest(r) || r.Context().Value(meshOwnPortKey{}) != nil || meshDeviceOverLoopback(r)
}

// meshDeviceAuthIn: the paired device's 24242 this request was admitted on
// (withMeshDeviceAuth), or nil.
func meshDeviceAuthIn(ctx context.Context) *nostr.Event {
	ev, _ := ctx.Value(meshDeviceAuthKey{}).(*nostr.Event)
	return ev
}

// isMeshDeviceAuth: auth is the device token this request was admitted on.
// The Blossom hooks accept a device key only then: a device key that did
// not pass withMeshDeviceAuth is a stranger's key, refused as before.
func isMeshDeviceAuth(ctx context.Context, auth *nostr.Event) bool {
	dev := meshDeviceAuthIn(ctx)
	return dev != nil && auth != nil && dev.ID == auth.ID && dev.PubKey == auth.PubKey
}

// meshDeviceVerb: the Blossom verb and blob a request acts on, for a device
// token. ok false: a device key may not do this.
func meshDeviceVerb(r *http.Request) (verb, sha string, spend, ok bool) {
	switch {
	case r.URL.Path == "/upload" && r.Method == http.MethodPut:
		// The hash is checked once the body is read (the door, and the
		// index's Keep for the own port).
		return "upload", strings.ToLower(r.Header.Get("X-SHA-256")), true, true
	case r.URL.Path == "/upload" && r.Method == http.MethodHead:
		// The pre-flight stores nothing; the PUT that follows spends it.
		return "upload", strings.ToLower(r.Header.Get("X-SHA-256")), false, true
	case blossomBlobPathRe.MatchString(r.URL.Path):
		sha := strings.ToLower(blossomBlobPathRe.FindStringSubmatch(r.URL.Path)[1])
		switch r.Method {
		case http.MethodGet:
			return "get", sha, true, true
		case http.MethodHead:
			// The check after a delete: no blob bytes, nothing changes.
			return "get", sha, false, true
		case http.MethodDelete:
			return "delete", sha, true, true
		}
	}
	return "", "", false, false
}

// withMeshDeviceAuth admits a Blossom request signed by a paired device's
// mesh key: checked, spent once (no replay until it expires), and carried in
// the context for the Blossom hooks. A request with no device token passes
// through unchanged, to the owner-key checks as before. Status 0 = go on.
func withMeshDeviceAuth(r *http.Request) (*http.Request, int, string) {
	if meshDeviceAuthIn(r.Context()) != nil {
		return r, 0, "" // the door already admitted it
	}
	header, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Nostr ")
	if !ok {
		return r, 0, ""
	}
	raw, err := decodeNostrAuthToken(header)
	if err != nil {
		return r, 0, ""
	}
	var ev nostr.Event
	if json.Unmarshal(raw, &ev) != nil || ev.Kind != 24242 {
		return r, 0, ""
	}
	if _, owner := whitelist()[ev.PubKey]; owner || !meshDevices.paired(ev.PubKey) {
		return r, 0, "" // owner path (kept until the apps switch) or a stranger
	}
	if !meshDeviceOverMesh(r) {
		// Tron, #1802: on the box the relay handler is also the public URL.
		// A device's mesh key is good only for what came in over the mesh.
		return r, http.StatusForbidden, "a device key is accepted only over the mesh"
	}
	verb, sha, spend, ok := meshDeviceVerb(r)
	if !ok {
		return r, http.StatusForbidden, "a device key cannot do this"
	}
	if code, why := meshDevices.checkBlobAuth(&ev, verb, sha); code != 0 {
		return r, code, why
	}
	if spend && !meshDevices.spend(ev.ID, authExpiration(&ev)) {
		// 409 as the door's owner path: "sign a new one and try again".
		return r, http.StatusConflict, "authorization already used"
	}
	return r.WithContext(context.WithValue(r.Context(), meshDeviceAuthKey{}, &ev)), 0, ""
}

// meshIndexKey: the key a blob record is filed under. A paired device's
// upload or delete acts on the owner's record, so copyOwnMediaSet (§4)
// counts the device's uploads and a device can only delete what is the
// owner's.
func meshIndexKey(ctx context.Context, pubkey string) string {
	if dev := meshDeviceAuthIn(ctx); dev != nil && dev.PubKey == pubkey && config.OwnerPubKey != "" {
		return config.OwnerPubKey
	}
	return pubkey
}

// meshOwnerIndex files a paired device's upload or delete under the owner's
// record (meshIndexKey), and refuses a device upload whose body is not a blob
// its token's x tags name: on the own port, Keep is the first point the hash
// is known.
type meshOwnerIndex struct {
	blossom.EventStoreBlobIndexWrapper
}

func (i meshOwnerIndex) Keep(ctx context.Context, blob blossom.BlobDescriptor, pubkey string) error {
	if dev := meshDeviceAuthIn(ctx); dev != nil && dev.PubKey == pubkey && dev.Tags.FindWithValue("x", blob.SHA256) == nil {
		return errors.New("authorization does not cover this blob")
	}
	return i.EventStoreBlobIndexWrapper.Keep(ctx, blob, meshIndexKey(ctx, pubkey))
}

func (i meshOwnerIndex) Delete(ctx context.Context, sha256 string, pubkey string) error {
	return i.EventStoreBlobIndexWrapper.Delete(ctx, sha256, meshIndexKey(ctx, pubkey))
}
