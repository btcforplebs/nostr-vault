package box

import (
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// Front is the box's one port. It sends each request to one of three places:
//
//   - /api/box/...                      → the box API (owner-only, NIP-98)
//   - relay and Blossom traffic          → the vault engine on loopback
//   - everything else (GET/HEAD)         → the web app's static files
//
// Relay traffic is any WebSocket upgrade (/, /private, /chat, /inbox, /feed)
// and NIP-11 (Accept: application/nostr+json). Blossom is any non-GET, and
// GET/HEAD of a blob (/<sha256>[.ext]) or a Blossom path (/list/, /upload,
// /mirror, /media, /report). With no web app, GETs go to the engine too, so
// its own page still shows.
type Front struct {
	API    http.Handler
	Engine http.Handler
	Web    http.Handler // nil: no web app
}

var blobPath = regexp.MustCompile(`^/[0-9a-fA-F]{64}(\.[A-Za-z0-9]{1,10})?$`)

var blossomPrefixes = []string{"/upload", "/mirror", "/media", "/report", "/list/"}

func (f *Front) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api/box" || strings.HasPrefix(r.URL.Path, "/api/box/") {
		f.API.ServeHTTP(w, r)
		return
	}
	if f.Web == nil || isEngineRequest(r) {
		f.Engine.ServeHTTP(w, r)
		return
	}
	f.Web.ServeHTTP(w, r)
}

func isEngineRequest(r *http.Request) bool {
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		return true
	}
	if strings.Contains(r.Header.Get("Accept"), "application/nostr+json") {
		return true
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return true // Blossom PUT/DELETE and CORS preflights
	}
	if blobPath.MatchString(r.URL.Path) {
		return true
	}
	for _, p := range blossomPrefixes {
		if r.URL.Path == strings.TrimSuffix(p, "/") || strings.HasPrefix(r.URL.Path, p) {
			return true
		}
	}
	return false
}

// EngineProxy forwards to the engine on loopback, WebSockets included. The
// client's own X-Forwarded-For is dropped and the real peer address set, so
// nobody can pick the address the engine's limits see.
func EngineProxy(port int) http.Handler {
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", itoa(port))}
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = pr.In.Host // the engine's Blossom URLs and NIP-42 use the name the client used
			pr.Out.Header.Del("X-Forwarded-For")
			pr.Out.Header.Del("X-Real-Ip")
			pr.Out.Header.Del("Forwarded")
			pr.SetXForwarded()
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "vault is starting or moving; try again shortly", http.StatusServiceUnavailable)
		},
	}
}

// WebApp serves dir as a single-page app: a path with no file behind it gets
// index.html, so the app's own routes load. Dotfiles are never served.
func WebApp(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clean := path.Clean("/" + r.URL.Path)
		for _, part := range strings.Split(clean, "/") {
			if strings.HasPrefix(part, ".") {
				http.NotFound(w, r)
				return
			}
		}
		full := filepath.Join(dir, filepath.FromSlash(clean))
		if st, err := os.Stat(full); err == nil && (!st.IsDir() || fileExists(filepath.Join(full, "index.html"))) {
			files.ServeHTTP(w, r)
			return
		}
		if path.Ext(clean) != "" {
			http.NotFound(w, r) // a missing asset is a 404, not the app shell
			return
		}
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}
