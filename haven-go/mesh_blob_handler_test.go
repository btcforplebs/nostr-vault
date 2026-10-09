package main

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/spf13/afero"
)

// Everything but GET/HEAD of a blob path must stop before the relay mux.
// (Allowed requests reach dynamicRelayHandler, which needs live relays.)
func TestMeshBlobHandlerRejectsNonBlobRequests(t *testing.T) {
	sha := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	cases := []struct{ method, path string }{
		{http.MethodGet, "/"},
		{http.MethodGet, "/feed"},
		{http.MethodGet, "/private"},
		{http.MethodGet, "/list/" + sha},
		{http.MethodGet, "/" + sha + "/x"},
		{http.MethodGet, "/" + sha[:63]},
		{http.MethodPut, "/upload"},
		{http.MethodPut, "/" + sha},
		{http.MethodDelete, "/" + sha},
		{http.MethodPost, "/" + sha},
		{http.MethodOptions, "/" + sha},
	}
	for _, c := range cases {
		w := httptest.NewRecorder()
		meshBlobHandler(w, httptest.NewRequest(c.method, c.path, nil))
		if w.Code != http.StatusNotFound {
			t.Errorf("%s %s: got %d, want 404", c.method, c.path, w.Code)
		}
	}
}

// A blob path must not carry a peer onto the relay: khatru routes websocket
// and NIP-11 by header before the path. The full handler is the control.
func TestMeshBlobHandlerKeepsPeersOffTheRelay(t *testing.T) {
	savedRelay, savedFs := outboxRelay, fs
	outboxRelay, fs = khatru.NewRelay(), afero.NewMemMapFs()
	defer func() { outboxRelay, fs = savedRelay, savedFs }()

	sha := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for _, h := range []struct {
		name     string
		handler  http.HandlerFunc
		wantRely bool
	}{
		{"full relay (control)", dynamicRelayHandler, true},
		{"mesh", meshBlobHandler, false},
	} {
		srv := httptest.NewServer(h.handler)

		// Raw handshake: a 101 means the peer is now talking to the relay.
		conn, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(conn, "GET /%s HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"+
			"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", sha)
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		status, _ := bufio.NewReader(conn).ReadString('\n')
		conn.Close()
		if got := strings.Contains(status, " 101 "); got != h.wantRely {
			t.Errorf("%s: websocket upgrade = %v (%q), want %v", h.name, got, status, h.wantRely)
		}

		info, _ := http.NewRequest(http.MethodGet, srv.URL+"/"+sha, nil)
		info.Header.Set("Accept", "application/nostr+json")
		resp, err := http.DefaultClient.Do(info)
		if err != nil {
			t.Fatalf("%s nip11: %v", h.name, err)
		}
		resp.Body.Close()
		if got := resp.Header.Get("Content-Type") == "application/nostr+json"; got != h.wantRely {
			t.Errorf("%s: NIP-11 served = %v, want %v", h.name, got, h.wantRely)
		}
		srv.Close()
	}
}
