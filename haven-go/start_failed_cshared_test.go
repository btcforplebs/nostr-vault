//go:build cshared

package main

import (
	"bytes"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// A start whose port is taken fails, and says so in one marker line the
// apps read. It used to carry on, print "listening at" and show Online
// while nothing listened for this vault.
func TestStartRelayFailsWhenThePortIsTaken(t *testing.T) {
	dir := t.TempDir()
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	npub, _ := nip19.EncodePublicKey(pk)
	empty := filepath.Join(dir, "none.json")
	if err := os.WriteFile(empty, []byte("[]"), 0o644); err != nil {
		t.Fatal(err)
	}
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	port := taken.Addr().(*net.TCPAddr).Port
	wd, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(wd) })
	for k, v := range map[string]string{
		"DATABASE_PATH":           filepath.Join(dir, "db"),
		"DB_ENGINE":               "badger",
		"OWNER_NPUB":              npub,
		"RELAY_PORT":              strconv.Itoa(port),
		"RELAY_BIND_ADDRESS":      "127.0.0.1",
		"IMPORT_SEED_RELAYS_FILE": empty,
		"BLASTR_RELAYS_FILE":      empty,
		"DM_RELAYS_FILE":          empty,
		"FEED_SYNC_RELAYS_FILE":   empty,
		"WOT_CACHE_PATH":          filepath.Join(dir, "wot_cache.json"),
		"HAVEN_MESH_PLAIN_PORT":   strconv.Itoa(freePort(t)),
	} {
		t.Setenv(k, v)
	}

	var out lockedBuffer
	prev := log.Writer()
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(prev) })

	StartRelayC(false)
	t.Cleanup(StopRelayC)
	if relayLC.current.Load() != nil {
		t.Fatal("the relay started with its port taken")
	}
	deadline := time.Now().Add(2 * time.Second)
	for !strings.Contains(out.String(), startFailedMarker) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	logged := out.String()
	if !strings.Contains(logged, startFailedMarker) || !strings.Contains(logged, "address already in use") {
		t.Fatalf("no start-failed marker naming the port conflict in the log:\n%s", tail(logged, 2000))
	}
	if strings.Contains(logged, "listening at") {
		t.Fatal(`a failed start still logged "listening at"`)
	}
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
