package box

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func named(name string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, name) })
}

func TestFrontRouting(t *testing.T) {
	web := t.TempDir()
	os.WriteFile(filepath.Join(web, "index.html"), []byte("app"), 0o644)
	os.WriteFile(filepath.Join(web, "app.js"), []byte("js"), 0o644)
	os.WriteFile(filepath.Join(web, ".env"), []byte("secret"), 0o644)
	f := &Front{API: named("api"), Engine: named("engine"), Web: WebApp(web)}
	blob := strings.Repeat("ab", 32)

	cases := []struct {
		method, path string
		hdr          map[string]string
		want         string
		code         int
	}{
		{"GET", "/api/box/status", nil, "api", 200},
		{"POST", "/api/box/move", nil, "api", 200},
		{"GET", "/", map[string]string{"Upgrade": "websocket", "Connection": "Upgrade"}, "engine", 200},
		{"GET", "/private", map[string]string{"Upgrade": "WebSocket"}, "engine", 200},
		{"GET", "/", map[string]string{"Accept": "application/nostr+json"}, "engine", 200},
		{"GET", "/" + blob, nil, "engine", 200},
		{"HEAD", "/" + blob + ".jpg", nil, "engine", 200},
		{"PUT", "/upload", nil, "engine", 200},
		{"HEAD", "/upload", nil, "engine", 200},
		{"DELETE", "/" + blob, nil, "engine", 200},
		{"GET", "/list/" + blob, nil, "engine", 200},
		{"OPTIONS", "/upload", nil, "engine", 200},
		{"GET", "/", nil, "app", 200},
		{"GET", "/app.js", nil, "js", 200},
		{"GET", "/wot/" + blob, nil, "app", 200}, // the app's own route
		{"GET", "/missing.css", nil, "", 404},
		{"GET", "/.env", nil, "", 404},
	}
	for _, c := range cases {
		r := httptest.NewRequest(c.method, c.path, nil)
		for k, v := range c.hdr {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		f.ServeHTTP(w, r)
		if w.Code != c.code || (c.want != "" && w.Body.String() != c.want) {
			t.Errorf("%s %s %v: got %d %q, want %d %q", c.method, c.path, c.hdr, w.Code, w.Body.String(), c.code, c.want)
		}
	}

	// No web app: GET / is the engine's own page.
	f.Web = nil
	w := httptest.NewRecorder()
	f.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Body.String() != "engine" {
		t.Fatalf("no web app: got %q", w.Body.String())
	}
}

// The proxy carries a WebSocket upgrade through, keeps the Host the client
// used, and replaces a forged X-Forwarded-For.
func TestEngineProxyUpgradeAndHeaders(t *testing.T) {
	var gotHost, gotXFF string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost, gotXFF = r.Host, r.Header.Get("X-Forwarded-For")
		if r.Header.Get("Upgrade") != "websocket" {
			io.WriteString(w, "plain")
			return
		}
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		rw.Flush()
		line, _ := rw.ReadString('\n')
		rw.WriteString("echo:" + line)
		rw.Flush()
	}))
	defer backend.Close()
	port := backend.Listener.Addr().(*net.TCPAddr).Port
	front := httptest.NewServer(&Front{API: named("api"), Engine: EngineProxy(port)})
	defer front.Close()

	req, _ := http.NewRequest("GET", front.URL+"/x", nil)
	req.Host = "box.lan:8080"
	req.Header.Set("X-Forwarded-For", "8.8.8.8")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if gotHost != "box.lan:8080" {
		t.Fatalf("engine saw Host %q", gotHost)
	}
	if strings.Contains(gotXFF, "8.8.8.8") || !strings.Contains(gotXFF, "127.0.0.1") {
		t.Fatalf("engine saw X-Forwarded-For %q", gotXFF)
	}

	conn, err := net.Dial("tcp", front.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "GET / HTTP/1.1\r\nHost: box\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: x\r\n\r\n")
	br := bufio.NewReader(conn)
	status, _ := br.ReadString('\n')
	if !strings.Contains(status, "101") {
		t.Fatalf("no upgrade through the proxy: %q", status)
	}
	for {
		l, _ := br.ReadString('\n')
		if l == "\r\n" || l == "" {
			break
		}
	}
	io.WriteString(conn, "hello\n")
	echo, _ := br.ReadString('\n')
	if echo != "echo:hello\n" {
		t.Fatalf("upgraded stream: got %q", echo)
	}
}

func TestEngineProxyDownIs503(t *testing.T) {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	w := httptest.NewRecorder()
	EngineProxy(port).ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 503 {
		t.Fatalf("got %d", w.Code)
	}
}
