package box

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// NIP-98 HTTP auth for the box API. Every /api/box/ request must carry
// "Authorization: Nostr <base64 kind-27235 event>" (Verify: from any signer;
// the API then decides what that signer may do, api.go; Check: the owner), for
// this exact method, host and path, at most authWindow old, with the body's
// sha256 in a payload tag when there is a body, and never seen before.

const (
	httpAuthKind = 27235
	authWindow   = 60 * time.Second
	maxBodyBytes = 64 << 10
)

// AuthError is a refused request: Status is 401 (no or bad proof) or 403
// (a valid proof from someone who is not the owner).
type AuthError struct {
	Status int
	Reason string
}

func (e *AuthError) Error() string { return e.Reason }

func unauthorized(format string, a ...any) *AuthError {
	return &AuthError{Status: http.StatusUnauthorized, Reason: fmt.Sprintf(format, a...)}
}

// OwnerAuth checks NIP-98 proofs against one owner and remembers the event
// ids it accepted, so a captured header (the LAN is plain HTTP) works once.
type OwnerAuth struct {
	OwnerHex string
	Now      func() time.Time

	mu   sync.Mutex
	seen map[string]time.Time
}

func NewOwnerAuth(ownerHex string) *OwnerAuth {
	return &OwnerAuth{OwnerHex: ownerHex, Now: time.Now, seen: map[string]time.Time{}}
}

// Proof is a request's checked NIP-98 proof: who signed it, its event id
// (for the replay check, FirstUse) and the body it covers.
type Proof struct {
	Pubkey string // hex, lowercase
	ID     string
	Body   []byte
}

// Check verifies r as the owner's and returns its body (read once, at most
// maxBodyBytes) so the handler can use it. r.Body is replaced with a fresh
// reader too.
func (a *OwnerAuth) Check(r *http.Request) ([]byte, error) {
	p, err := a.Verify(r)
	if err != nil {
		return nil, err
	}
	// Owner last: a well-formed proof from anyone else is 403, not 401.
	if !strings.EqualFold(p.Pubkey, a.OwnerHex) {
		return nil, &AuthError{Status: http.StatusForbidden, Reason: "only the owner may use the box API"}
	}
	if !a.FirstUse(p.ID) {
		return nil, unauthorized("authorization was already used")
	}
	return p.Body, nil
}

// Verify checks r's NIP-98 proof from any signer: kind, time window,
// signature, id, method, URL and body hash. It does not check who signed
// or record the id: the caller decides what the signer may do, then calls
// FirstUse before acting, so a stranger's refused proofs fill no cache.
func (a *OwnerAuth) Verify(r *http.Request) (Proof, error) {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Nostr ") {
		return Proof{}, unauthorized("missing Authorization: Nostr header")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(header, "Nostr ")))
	if err != nil {
		return Proof{}, unauthorized("authorization is not base64")
	}
	var ev nostr.Event
	if err := json.Unmarshal(raw, &ev); err != nil {
		return Proof{}, unauthorized("authorization is not a nostr event")
	}
	if ev.Kind != httpAuthKind {
		return Proof{}, unauthorized("authorization event must be kind %d", httpAuthKind)
	}
	now := a.Now()
	at := ev.CreatedAt.Time()
	if at.Before(now.Add(-authWindow)) || at.After(now.Add(authWindow)) {
		return Proof{}, unauthorized("authorization event is outside the %s window", authWindow)
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return Proof{}, unauthorized("authorization signature is invalid")
	}
	// The signature covers the serialized event, not the id as sent, and the
	// replay cache is keyed on the id: an unchecked id lets one captured
	// header be replayed under any number of made-up ids.
	if !ev.CheckID() {
		return Proof{}, unauthorized("authorization event id does not match its content")
	}

	method := tagValue(ev.Tags, "method")
	if !strings.EqualFold(method, r.Method) {
		return Proof{}, unauthorized("authorization is for method %q, not %s", method, r.Method)
	}
	if err := matchURL(tagValue(ev.Tags, "u"), r); err != nil {
		return Proof{}, unauthorized("%v", err)
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		return Proof{}, unauthorized("reading body: %v", err)
	}
	if len(body) > maxBodyBytes {
		return Proof{}, &AuthError{Status: http.StatusRequestEntityTooLarge, Reason: "body too large"}
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	// A body must be named by its hash; an empty body may be named or not.
	if payload := tagValue(ev.Tags, "payload"); len(body) > 0 || payload != "" {
		sum := sha256.Sum256(body)
		if !strings.EqualFold(payload, hex.EncodeToString(sum[:])) {
			return Proof{}, unauthorized("payload tag does not match the body's sha256")
		}
	}

	return Proof{Pubkey: strings.ToLower(ev.PubKey), ID: ev.ID, Body: body}, nil
}

// FirstUse records a verified proof's id; false if it was used already.
func (a *OwnerAuth) FirstUse(id string) bool { return a.firstUse(id, a.Now()) }

// firstUse records id; false if it was seen within the window. The cache is
// memory only: a header captured in the last authWindow works once more
// after havend restarts. Accepted: a restart takes longer than most of the
// window, and the replay is limited to the same method, URL and body. Entries older
// than twice the window are dropped: an event that old fails the time check.
func (a *OwnerAuth) firstUse(id string, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for k, t := range a.seen {
		if now.Sub(t) > 2*authWindow {
			delete(a.seen, k)
		}
	}
	if _, dup := a.seen[id]; dup {
		return false
	}
	a.seen[id] = now
	return true
}

func tagValue(tags nostr.Tags, name string) string {
	for _, t := range tags {
		if len(t) >= 2 && t[0] == name {
			return t[1]
		}
	}
	return ""
}

// matchURL: the signed u tag must name this request's host (as the client
// sent it), path and query. The scheme is not compared: the box is plain
// HTTP behind whatever the client reached it through (LAN, mesh).
func matchURL(signed string, r *http.Request) error {
	if signed == "" {
		return errors.New("authorization has no u tag")
	}
	u, err := url.Parse(signed)
	if err != nil || !u.IsAbs() || u.Host == "" {
		return fmt.Errorf("authorization u tag %q is not an absolute URL", signed)
	}
	if !sameHost(u, r.Host) {
		return fmt.Errorf("authorization is for host %q, not %q", u.Host, r.Host)
	}
	if u.EscapedPath() != r.URL.EscapedPath() || u.RawQuery != r.URL.RawQuery {
		return fmt.Errorf("authorization is for %q, not %q", u.RequestURI(), r.URL.RequestURI())
	}
	return nil
}

func sameHost(u *url.URL, reqHost string) bool {
	h1, p1 := splitHostPort(u.Host, defaultPort(u.Scheme))
	h2, p2 := splitHostPort(reqHost, "")
	if p2 == "" {
		p2 = p1 // the request line omitted the port: it was the scheme default
	}
	return strings.EqualFold(h1, h2) && p1 == p2
}

func defaultPort(scheme string) string {
	if strings.EqualFold(scheme, "https") || strings.EqualFold(scheme, "wss") {
		return "443"
	}
	return "80"
}

func splitHostPort(hostport, def string) (string, string) {
	if h, p, err := net.SplitHostPort(hostport); err == nil {
		return strings.Trim(h, "[]"), p
	}
	return strings.Trim(hostport, "[]"), def
}
