//go:build !cshared && !(js && wasm)

package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
)

// startMeshDoorFromEnv opens the mesh door for the command-line engine (the
// Linux box's haven-engine), which has no host to call SetMeshServingC: with
// HAVEN_MESH_PLAIN_PORT set it serves meshHandler on 127.0.0.1 at that port
// for the life of the process, behind the same listener caps as the apps'.
// Strangers nv-mesh sends there get only what the door gives any mesh peer
// (blob reads, owner-signed uploads and events); the relay port stays
// closed to them. Unset: no door, nil server.
func startMeshDoorFromEnv() (*http.Server, error) {
	raw := strings.TrimSpace(os.Getenv("HAVEN_MESH_PLAIN_PORT"))
	if raw == "" {
		return nil, nil
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port <= 0 || port > 65535 {
		return nil, fmt.Errorf("HAVEN_MESH_PLAIN_PORT %q is not a port", raw)
	}
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	srv := newMeshServer(addr)
	go func() {
		if err := srv.Serve(newMeshListener(ln)); err != nil && err != http.ErrServerClosed {
			log.Printf("🚫 mesh HTTP server exited: %v", err)
		}
	}()
	log.Printf("🔗 mesh listening at http://%s", addr)
	return srv, nil
}
