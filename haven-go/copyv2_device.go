//go:build !(js && wasm)

package main

// Own devices' web domains, device to device (multi-Mac rules §3.3).
//
// A Mac or box with a public https domain tells the owner's other devices
// which domain is its own, so they can tell which device the owner's lists
// name as public on the web. It goes only over the mesh, inside a catch-up
// (or the first copy) on the own-device port, as a proof the device signs
// with its own mesh key (WEB_DOMAIN_PROOF, made by the Mac app, which holds
// that key; the engine never does). The receiver keeps it only when the
// signer is the device on the other end: the peer it dialed, or the device
// the caller's copy token was issued to (copyToken.Device). The proof is
// never published: its kind is outside every list and nothing relays it. A
// device with no public domain (mesh only, a phone, a home address, a box,
// whose mesh key havend never reads) sends nothing, and the other side then
// forgets any domain it had for it.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"sync"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

const (
	copyPeerDomainsFile = "copy_peer_domains.json"
	// copyDomainProofKind: the proof's kind, ephemeral and never sent to a
	// relay (the Mac app's MeshDomainProof.kind is the same number).
	copyDomainProofKind = 21240
)

var copyPeerDomainsMu sync.Mutex

// copyOwnDomainProof is WEB_DOMAIN_PROOF, set only by the Mac app, when it
// still checks out as this vault's own: nil otherwise, and then nothing is
// sent.
func copyOwnDomainProof() *nostr.Event {
	if strings.TrimSpace(config.WebDomainProof) == "" {
		return nil
	}
	var ev nostr.Event
	if json.Unmarshal([]byte(config.WebDomainProof), &ev) != nil {
		return nil
	}
	self := meshDevices.selfKey()
	if _, ok := copyDomainFromProof(&ev, self); !ok || self == "" {
		return nil
	}
	return &ev
}

// copyDomainFromProof: the domain ev proves for signer (hex mesh key), when
// ev is a valid proof signed by signer naming a public name.
func copyDomainFromProof(ev *nostr.Event, signer string) (string, bool) {
	if ev == nil || signer == "" || ev.Kind != copyDomainProofKind || !strings.EqualFold(ev.PubKey, signer) {
		return "", false
	}
	if !ev.CheckID() {
		return "", false
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return "", false
	}
	d := copyWebDomain(tagValueOf(ev.Tags, "domain"))
	return d, d != ""
}

// copyWebDomain: raw as a bare lowercase host when it is a public DNS name,
// else "". No IPs ever, no ports, no home or mesh names.
func copyWebDomain(raw string) string {
	h := strings.ToLower(strings.TrimSpace(raw))
	for _, scheme := range []string{"https://", "wss://", "http://", "ws://"} {
		h = strings.TrimPrefix(h, scheme)
	}
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	h = strings.TrimSuffix(h, ".")
	if h == "" || len(h) > 253 || strings.ContainsAny(h, ":[]@ ") {
		return ""
	}
	if _, err := netip.ParseAddr(h); err == nil {
		return ""
	}
	labels := strings.Split(h, ".")
	if len(labels) < 2 {
		return ""
	}
	for _, l := range labels {
		if l == "" || len(l) > 63 || l[0] == '-' || l[len(l)-1] == '-' {
			return ""
		}
		for _, r := range l {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return ""
			}
		}
	}
	tld := labels[len(labels)-1]
	if tld[0] >= '0' && tld[0] <= '9' {
		return ""
	}
	for _, private := range []string{"local", "localhost", "fips", "onion", "internal", "lan", "home", "arpa", "test", "invalid"} {
		if tld == private {
			return ""
		}
	}
	if strings.HasSuffix(h, ".ts.net") || strings.HasSuffix(h, ".home.arpa") {
		return ""
	}
	return h
}

type copyPeerDomain struct {
	Domain string `json:"domain"`
	// At: the proof's created_at, so an older proof never undoes a newer one.
	At int64 `json:"at"`
}

func loadCopyPeerDomains() map[string]copyPeerDomain {
	out := map[string]copyPeerDomain{}
	if raw, err := os.ReadFile(copyPeerDomainsFile); err == nil {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

// setCopyPeerDomain records peer's (a mesh npub's) domain from a proof made
// at `at`; "" forgets it, so a Mac that lost its domain stops being one.
func setCopyPeerDomain(peerNpub, domain string, at int64) {
	if !strings.HasPrefix(peerNpub, "npub1") {
		return
	}
	copyPeerDomainsMu.Lock()
	defer copyPeerDomainsMu.Unlock()
	all := loadCopyPeerDomains()
	old, had := all[peerNpub]
	switch {
	case domain == "" && !had:
		return
	case domain == "":
		delete(all, peerNpub)
	case had && (at < old.At || old == (copyPeerDomain{domain, at})):
		return
	default:
		all[peerNpub] = copyPeerDomain{domain, at}
	}
	raw, _ := json.Marshal(all)
	tmp := copyPeerDomainsFile + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err == nil {
		_ = os.Rename(tmp, copyPeerDomainsFile)
	}
}

// copyPeerDomainsJSON is CopyPeerDomainsC: {"npub1…": "host"}, only for
// devices still paired (when the app has handed the set over).
func copyPeerDomainsJSON() string {
	copyPeerDomainsMu.Lock()
	all := loadCopyPeerDomains()
	copyPeerDomainsMu.Unlock()
	out := map[string]string{}
	for npub, d := range all {
		if meshDevices.selfKey() != "" {
			if _, pk, err := nip19.Decode(npub); err != nil || !meshDevices.paired(pk.(string)) {
				continue
			}
		}
		if host := copyWebDomain(d.Domain); host != "" {
			out[npub] = host
		}
	}
	raw, _ := json.Marshal(out)
	return string(raw)
}

// copyDeviceInfo is the body both ways: the sender's signed proof, or none.
type copyDeviceInfo struct {
	Proof *nostr.Event `json:"proof,omitempty"`
}

// recordProof keeps what in proves for signerHex under its npub; no proof,
// or one that does not check out, forgets it.
func recordProof(signerHex string, in copyDeviceInfo) {
	npub, err := nip19.EncodePublicKey(signerHex)
	if signerHex == "" || err != nil {
		return
	}
	d, ok := copyDomainFromProof(in.Proof, signerHex)
	if !ok {
		setCopyPeerDomain(npub, "", 0)
		return
	}
	setCopyPeerDomain(npub, d, int64(in.Proof.CreatedAt))
}

// serveSyncDevice is GET and PUT /copy/v2/sync/device, behind the device's
// bearer: GET hands over this vault's own proof, PUT records the caller's,
// signed by the device the token was issued to.
func (s *copyServer) serveSyncDevice(w http.ResponseWriter, r *http.Request, tokenHash string) {
	switch r.Method {
	case http.MethodGet:
		copyJSON(w, http.StatusOK, copyDeviceInfo{Proof: copyOwnDomainProof()})
	case http.MethodPut:
		device := s.tokenDevice(tokenHash)
		if device == "" {
			http.Error(w, "auth_refused", http.StatusUnauthorized)
			return
		}
		var in copyDeviceInfo
		if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&in); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		recordProof(device, in)
		copyJSON(w, http.StatusOK, map[string]string{"device": "ok"})
	default:
		http.NotFound(w, r)
	}
}

// tokenDevice: the device (hex mesh key) a live token was issued to.
func (s *copyServer) tokenDevice(hash string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, t := range s.tokens {
		if t.Hash == hash {
			return strings.ToLower(t.Device)
		}
	}
	return ""
}

// syncDevice: A's proof recorded under A (the peer this client dialed),
// then B's own sent. An A from before this answers 404 and nothing changes.
func (c *copyClient) syncDevice(ctx context.Context) {
	resp, err := c.do(ctx, http.MethodGet, "/copy/v2/sync/device", nil, nil)
	if err != nil {
		return
	}
	var theirs copyDeviceInfo
	ok := resp.StatusCode == http.StatusOK && json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&theirs) == nil
	resp.Body.Close()
	if !ok {
		return
	}
	recordProof(meshKeyHex(strings.TrimSpace(c.peer)), theirs)
	raw, _ := json.Marshal(copyDeviceInfo{Proof: copyOwnDomainProof()})
	if resp, err := c.do(ctx, http.MethodPut, "/copy/v2/sync/device", map[string]string{"Content-Type": "application/json"}, raw); err == nil {
		resp.Body.Close()
	}
}
