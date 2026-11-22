package box

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Claim mode: a store (Umbrel) installs the box with no owner and gives it a
// setup code (NV_SETUP_CODE) that only the store's user can read. Until
// someone sends the owner's npub with that code, havend serves nothing but
// this page: no vault, no relay, no box API. The first correct claim writes
// box/owner and closes Done; havend then starts as the normal box for that
// owner. A visitor without the code can never claim the box, and after the
// claim the page is gone (box/owner is read on every start).

// Wrong codes are capped per client (claimMaxFails a minute from one
// address) and for the whole box (claimMaxFailsAll a minute) by a
// failLimiter (ratelimit.go).
const (
	claimFailWindow  = time.Minute
	claimMaxFails    = 5
	claimMaxFailsAll = 100
	claimMaxClients  = 1024
)

// Claim serves the setup page and takes the one claim.
type Claim struct {
	Code      string // NV_SETUP_CODE
	OwnerFile string // box/owner
	Done      chan struct{}
	Now       func() time.Time

	mu      sync.Mutex
	claimed bool
	limit   failLimiter
}

// NewClaim is a Claim for cfg (cfg.Claiming() must be true).
func NewClaim(cfg Config) *Claim {
	return &Claim{Code: cfg.SetupCode, OwnerFile: cfg.OwnerFile(), Done: make(chan struct{}), Now: time.Now}
}

// finish marks the box claimed and lets havend go on (once).
func (c *Claim) finish() {
	if !c.claimed {
		c.claimed = true
		close(c.Done)
	}
}

// ServeHTTP: GET / or /setup is the page, POST /setup the claim, anything
// else 503 (the vault does not run until the box has an owner).
func (c *Claim) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
	switch {
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && (r.URL.Path == "/" || r.URL.Path == "/setup"):
		c.page(w, http.StatusOK, claimPage{})
	case r.Method == http.MethodPost && r.URL.Path == "/setup":
		c.post(w, r)
	default:
		http.Error(w, "This box isn't set up yet. Open the box's address to claim it with the setup code.", http.StatusServiceUnavailable)
	}
}

func (c *Claim) post(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		c.page(w, http.StatusBadRequest, claimPage{Error: "The form didn't come through. Try again."})
		return
	}
	npubIn := strings.TrimSpace(r.PostFormValue("npub"))
	codeIn := strings.TrimSpace(r.PostFormValue("code"))

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.claimed {
		c.page(w, http.StatusConflict, claimPage{Error: "This box already has an owner."})
		return
	}
	now := c.Now()
	client := clientOf(r)
	if c.limit.window == 0 {
		c.limit = failLimiter{window: claimFailWindow, maxFails: claimMaxFails, maxAll: claimMaxFailsAll, maxClients: claimMaxClients}
	}
	if c.limit.blocked(client, now) {
		w.Header().Set("Retry-After", "60")
		c.page(w, http.StatusTooManyRequests, claimPage{Error: "Too many wrong codes. Wait a minute, then try again.", Npub: npubIn})
		return
	}
	if !sameCode(codeIn, c.Code) {
		c.limit.fail(client, now)
		log.Printf("box: claim refused: wrong setup code")
		c.page(w, http.StatusForbidden, claimPage{Error: "That setup code isn't right. Copy it again from your store's app page.", Npub: npubIn})
		return
	}
	hexKey, npub, err := ParseOwner(npubIn)
	if err != nil {
		msg := "That isn't an npub. Paste your public key (npub1…)."
		if strings.HasPrefix(npubIn, "nsec") {
			msg = "That is a secret key (nsec). Never paste it anywhere: paste your npub instead."
		}
		c.page(w, http.StatusBadRequest, claimPage{Error: msg})
		return
	}
	if err := WriteOwnerFile(c.OwnerFile, npub); err != nil {
		if errors.Is(err, fs.ErrExist) {
			// Saved already (another claim, or an owner put there by hand):
			// havend reads it and starts as that owner's box.
			c.finish()
			c.page(w, http.StatusConflict, claimPage{Error: "This box already has an owner."})
			return
		}
		log.Printf("box: claim: saving the owner: %v", err)
		c.page(w, http.StatusInternalServerError, claimPage{Error: "The box couldn't save its owner. Check its logs."})
		return
	}
	log.Printf("box: claimed by %s (%s)", npub, hexKey)
	c.page(w, http.StatusOK, claimPage{Done: true, Npub: npub})
	c.finish()
}

// clientOf is the request's peer address without the port. Claim mode is
// served straight on NV_PORT, so RemoteAddr is the visitor (no proxy header
// is trusted).
func clientOf(r *http.Request) string {
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// sameCode compares in constant time: hashing first makes the lengths equal.
func sameCode(got, want string) bool {
	g, w := sha256.Sum256([]byte(got)), sha256.Sum256([]byte(want))
	return want != "" && subtle.ConstantTimeCompare(g[:], w[:]) == 1
}

// WriteOwnerFile saves npub to path only if path is not there yet: the file
// is written whole under a temporary name, then linked into place, which
// fails with fs.ErrExist when an owner is already saved. Never overwrites.
func WriteOwnerFile(path, npub string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".owner-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(npub + "\n"); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Link(tmp.Name(), path); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("%s: %w", path, fs.ErrExist)
		}
		return err
	}
	if d, err := os.Open(filepath.Dir(path)); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

type claimPage struct {
	Error string
	Npub  string
	Done  bool
}

func (c *Claim) page(w http.ResponseWriter, status int, p claimPage) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_ = claimTmpl.Execute(w, p)
}

var claimTmpl = template.Must(template.New("claim").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Set up Nostr Vault</title>
<style>
body{font:16px/1.45 system-ui,sans-serif;background:#111;color:#eee;margin:0;display:flex;justify-content:center}
main{max-width:30rem;padding:2rem 1.25rem}
h1{font-size:1.4rem;margin:0 0 .75rem}
label{display:block;margin:1rem 0 .25rem;font-weight:600}
input{width:100%;box-sizing:border-box;padding:.6rem;border-radius:.5rem;border:1px solid #555;background:#1c1c1c;color:#eee;font:inherit}
button{margin-top:1.25rem;padding:.6rem 1.2rem;border:0;border-radius:.5rem;background:#8b5cf6;color:#fff;font:inherit;font-weight:600}
.err{color:#ff8a8a}.muted{color:#aaa;font-size:.9rem}
code{word-break:break-all}
</style></head><body><main>
{{if .Done}}
<h1>Your vault is yours</h1>
<p>This box now belongs to <code>{{.Npub}}</code>. It is starting as your vault: reload this page in a few seconds and sign in with that account.</p>
{{else}}
<h1>Set up Nostr Vault</h1>
<p>Claim this box with your Nostr account. Only someone with the setup code can do this, and only once.</p>
{{if .Error}}<p class="err" role="alert">{{.Error}}</p>{{end}}
<form method="post" action="/setup">
<label for="npub">Your npub</label>
<input id="npub" name="npub" value="{{.Npub}}" placeholder="npub1…" autocomplete="off" autocapitalize="off" spellcheck="false" required>
<label for="code">Setup code</label>
<input id="code" name="code" type="password" autocomplete="off" required>
<p class="muted">The setup code is on this app's page in your store (Umbrel shows it as the app's password). Paste your npub, never your nsec.</p>
<button type="submit">Claim this box</button>
</form>
{{end}}
</main></body></html>
`))
