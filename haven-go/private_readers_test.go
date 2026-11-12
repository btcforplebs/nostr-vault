package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Every added account has vault space for its own notes and uploads, but
// only the owner and accounts with a key or signer on this device read the
// private side (Logen, 2026-11-12, PR #1971). The "watch" actor is an added
// npub whose nsec someone else holds: whitelisted, not a private reader.

// withReaders makes watch an added account (whitelisted) and sets the
// private readers to readers. Undone at cleanup.
func withReaders(t *testing.T, watch string, readers ...string) {
	t.Helper()
	savedWL, savedR := config.WhitelistedPubKeys, config.PrivateReaderPubKeys
	wl := map[string]struct{}{watch: {}}
	for pk := range savedWL {
		wl[pk] = struct{}{}
	}
	config.WhitelistedPubKeys = wl
	r := map[string]struct{}{}
	for _, pk := range readers {
		r[pk] = struct{}{}
	}
	config.PrivateReaderPubKeys = r
	t.Cleanup(func() { config.WhitelistedPubKeys, config.PrivateReaderPubKeys = savedWL, savedR })
}

func TestPrivateReadsRefuseAnAddedNpubWithoutAKeyHere(t *testing.T) {
	a := startPolicyHaven(t)
	watchSK, watch := newActor()
	withReaders(t, watch, a.owner)

	for _, path := range []string{"/private", "/lists"} {
		a.runQueryCases(t, path, nostr.Filter{Kinds: []int{nostr.KindTextNote, 3}}, []queryCase{
			{name: "privateReaders" + path + ": authed as an added npub, closed", authSK: watchSK, closedBy: closedNotWhitelistedQ},
			{name: "privateReaders" + path + ": authed as owner, EOSE", authSK: a.ownerSK},
		})
	}
	// Its own space: it still posts its own notes, AUTH or not.
	a.runPublishCases(t, "", []publishCase{
		{name: "vault space/outbox: added npub's own note, unauthenticated, accepted", event: note(watchSK, nil)},
	})
	a.runPublishCases(t, "/private", []publishCase{
		{name: "vault space/private: added npub's own note, unauthenticated, accepted", event: note(watchSK, nil)},
	})
}

// An app that names no readers file (Android, the browser vault) keeps the
// old rule: every whitelisted key reads.
func TestPrivateReadsWithoutAReadersFileFollowTheWhitelist(t *testing.T) {
	a := startPolicyHaven(t)
	watchSK, watch := newActor()
	withReaders(t, watch)
	config.PrivateReaderPubKeys = nil
	a.runQueryCases(t, "/private", nostr.Filter{Kinds: []int{nostr.KindTextNote}}, []queryCase{
		{name: "privateReaders/private: no file, authed as added npub, EOSE", authSK: watchSK},
	})
}

func blobGetAuth(t *testing.T, sk, x string) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: 24242, CreatedAt: nostr.Now(), Content: "get",
		Tags: nostr.Tags{{"t", "get"}, {"x", x}, {"expiration", strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)}}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func TestBlobReadsRefuseAnAddedNpubWithoutAKeyHere(t *testing.T) {
	ownerSK, owner := withOwner(t)
	watchSK, watch := newActor()
	withReaders(t, watch, owner)
	private := blobHash('p')

	// The full blob list on the relay port.
	if ownerOrDeviceAuth(context.Background(), blobGetAuth(t, watchSK, private)) {
		t.Error("blob list: an added npub's signed list was accepted")
	}
	if !ownerOrDeviceAuth(context.Background(), blobGetAuth(t, ownerSK, private)) {
		t.Error("blob list: the owner's signed list was refused")
	}

	// An unposted blob over the mesh (GET, then HEAD).
	mesh := context.WithValue(context.Background(), meshPeerKey{}, "peer")
	if reject, _, _ := meshBlobRejectGet(mesh, blobGetAuth(t, watchSK, private), private, ""); !reject {
		t.Error("mesh GET: an added npub read an unposted blob")
	}
	if reject, _, _ := meshBlobRejectGet(mesh, blobGetAuth(t, ownerSK, private), private, ""); reject {
		t.Error("mesh GET: the owner was refused an unposted blob")
	}
	head := func(sk string) bool {
		j, _ := json.Marshal(blobGetAuth(t, sk, private))
		r, _ := http.NewRequest(http.MethodHead, "http://mesh/"+private, nil)
		r.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(j))
		return meshOwnerGetAuthorized(r, private)
	}
	if head(watchSK) {
		t.Error("mesh HEAD: an added npub's get token was accepted")
	}
	if !head(ownerSK) {
		t.Error("mesh HEAD: the owner's get token was refused")
	}
}

// A named readers file that cannot be read leaves the owner alone: fail
// closed, never back to the whole whitelist.
func TestPrivateReadersFileFailsClosed(t *testing.T) {
	if privateReadersFromFile("") != nil {
		t.Fatal("no file named must mean no readers set (the whitelist reads)")
	}
	missing := privateReadersFromFile(filepath.Join(t.TempDir(), "absent.json"))
	if missing == nil || len(missing) != 0 {
		t.Fatalf("a missing file must give an empty set, got %v", missing)
	}

	_, owner := newActor()
	npub, _ := nip19.EncodePublicKey(owner)
	t.Setenv("OWNER_NPUB", npub)
	t.Setenv("PRIVATE_READER_NPUBS_FILE", filepath.Join(t.TempDir(), "absent.json"))
	saved := config
	t.Cleanup(func() { config = saved })
	config = loadConfig()
	if len(config.PrivateReaderPubKeys) != 1 || !isPrivateReader(owner) {
		t.Fatalf("readers with an unreadable file = %v, want only the owner", config.PrivateReaderPubKeys)
	}
}
