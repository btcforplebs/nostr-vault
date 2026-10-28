package main

import (
	"net"
	"net/http"
	"testing"
	"time"
)

// A hijacked connection leaves the cycle's set when it closes, so a
// long-running relay does not keep every WebSocket it ever accepted.
func TestHijackedConnLeavesSetOnClose(t *testing.T) {
	c := newRelayCycle()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hijacked := make(chan net.Conn, 1)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		hijacked <- conn
	})}
	c.trackHijacked(srv)
	go srv.Serve(c.trackConns(ln))
	defer srv.Close()

	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))

	var conn net.Conn
	select {
	case conn = <-hijacked:
	case <-time.After(2 * time.Second):
		t.Fatal("handler never hijacked")
	}
	size := func() int {
		c.hijackedMu.Lock()
		defer c.hijackedMu.Unlock()
		return len(c.hijacked)
	}
	if n := size(); n != 1 {
		t.Fatalf("tracked %d hijacked conns, want 1", n)
	}
	conn.Close()
	if n := size(); n != 0 {
		t.Fatalf("tracked %d hijacked conns after close, want 0", n)
	}
}
