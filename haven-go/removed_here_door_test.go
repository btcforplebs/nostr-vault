package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
)

// A paired phone's queued upload of a file the owner removed from this
// device is refused for good over the mesh door; anything else, and the
// app's own Save to Vault over the local port, goes through.
func TestMeshDoorRefusesRemovedHere(t *testing.T) {
	root := t.TempDir()
	prevWD, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(prevWD) })
	t.Cleanup(func() { copyRemovedHere.set = nil })

	gone, kept := strings.Repeat("ab", 32), strings.Repeat("cd", 32)
	// Listed under another account, upper-cased: the door ignores both.
	list := `{"byAccount":{"` + strings.Repeat("b", 64) + `":["` + strings.ToUpper(gone) + `"]}}`
	if err := os.WriteFile(copyRemovedHereFile, []byte(list), 0o600); err != nil {
		t.Fatal(err)
	}

	mesh := context.WithValue(context.Background(), meshPeerKey{}, "peer")
	if reject, why, code := blobRemovedHere(mesh, nil, gone, 0); !reject || code != 403 || why == "" {
		t.Fatalf("mesh upload of a removed file: %v %q %d", reject, why, code)
	}
	if reject, _, _ := blobRemovedHere(mesh, nil, kept, 0); reject {
		t.Fatal("a file not on the list is accepted over the mesh")
	}
	if reject, _, _ := blobRemovedHere(context.Background(), nil, gone, 0); reject {
		t.Fatal("the app's own Save to Vault (local port) is never blocked here")
	}

	// The Blossom server the mesh door feeds runs it (wireBlobReceive).
	bs := &blossom.BlossomServer{}
	wireBlobReceive(bs)
	refused := false
	for _, f := range bs.RejectBlob {
		if r, why, code := f(mesh, &nostr.Event{Kind: 24242, Tags: nostr.Tags{{"x", gone}}}, gone, 0); r && code == 403 && why == "removed from this device" {
			refused = true
		}
	}
	if !refused {
		t.Fatal("wireBlobReceive does not refuse a removed file over the mesh")
	}

	// Taken off the list (Save to Vault): accepted again.
	if err := os.WriteFile(copyRemovedHereFile, []byte(`{"byAccount":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if reject, _, _ := blobRemovedHere(mesh, nil, gone, 0); reject {
		t.Fatal("a cleared hash must not stay refused")
	}
}
