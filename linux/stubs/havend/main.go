// Stand-in for havend (haven-go/cmd/havend, Tal) until it lands: it holds the box's one port the way the real one
// will, so the image, the supervisor and install.sh can be built and tested now. It serves the web app (NV_WEB_DIR)
// at /vault/ and sends a plain GET / there; the relay websocket at / and the owner-only /api/box/ answer 501, and
// GET /api/box/status says it is a stub. It keeps nothing: no key is made, nothing is written to NV_DATA_DIR.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	port, web := env("NV_PORT", "8080"), env("NV_WEB_DIR", "/app/web")
	started := time.Now()
	files := http.StripPrefix("/vault/", http.FileServer(http.Dir(web)))
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.EqualFold(r.Header.Get("Upgrade"), "websocket"):
			http.Error(w, "relay not here yet (havend stub)", http.StatusNotImplemented)
		case r.URL.Path == "/":
			http.Redirect(w, r, "/vault/", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	})
	mux.HandleFunc("/vault/", func(w http.ResponseWriter, r *http.Request) {
		// The app routes by hash; any other path under /vault/ that isn't a file is the app itself.
		if _, err := os.Stat(filepath.Join(web, filepath.Clean("/"+strings.TrimPrefix(r.URL.Path, "/vault/")))); err != nil {
			http.ServeFile(w, r, filepath.Join(web, "index.html"))
			return
		}
		files.ServeHTTP(w, r)
	})
	mux.HandleFunc("/api/box/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"version": "stub", "uptime": int(time.Since(started).Seconds()), "stub": true})
	})
	mux.HandleFunc("/api/box/", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "box API not here yet (havend stub)", http.StatusNotImplemented)
	})
	log.Printf("havend stub on :%s, web app from %s, owner %s", port, web, os.Getenv("NV_OWNER"))
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
