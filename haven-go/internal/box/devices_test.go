package box

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func npubOf(t *testing.T, k testKey) string {
	n, err := nip19.EncodePublicKey(k.pk)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestMeshEntriesExactFormOnly(t *testing.T) {
	a, b := newTestKey(t), newTestKey(t)
	na, nb := npubOf(t, a), npubOf(t, b)
	ev := &nostr.Event{Kind: 10063, Tags: nostr.Tags{
		{"server", "https://blossom.example/"},
		{"server", "fipsmesh://" + na + "/"},
		{"server", "fipsmesh://" + na + "/"},                  // duplicate
		{"server", "fipsmesh://" + nb + "/?v=1"},              // query allowed
		{"server", "fipsmesh://" + strings.ToUpper(nb) + "/"}, // uppercase refused
		{"server", "FIPSMESH://" + nb + "/"},
		{"server", "fipsmesh://" + nb + "/blob"}, // other paths reserved
		{"server", "fipsmesh://" + nb},           // no slash
		{"server", "fipsmesh://npub1notakey/"},
		{"relay", "fipsmesh://" + nb + "/"},
	}}
	got := MeshEntries(ev)
	if len(got) != 2 || got[0].Pubkey != a.pk || got[1].Pubkey != b.pk {
		t.Fatalf("got %+v", got)
	}
}

type fakeLists struct {
	ev    *nostr.Event
	src   string
	calls int
}

func (f *fakeLists) Newest(context.Context, string) (*nostr.Event, string) {
	f.calls++
	return f.ev, f.src
}

func TestDevicesApprovalFollowsTheNewestList(t *testing.T) {
	owner, phone := newTestKey(t), newTestKey(t)
	key, err := LoadOrCreateDeviceKey(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	src := &fakeLists{}
	d := &Devices{OwnerHex: owner.pk, Key: key, Source: src, TTL: time.Nanosecond}

	r := d.Report(context.Background())
	if r.Box.Approved || r.Source != "none" || r.Hint == "" || r.Box.Address != "fipsmesh://"+key.Npub+"/" {
		t.Fatalf("no list: %+v", r)
	}

	src.ev = owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now(), Tags: nostr.Tags{
		{"server", "fipsmesh://" + npubOf(t, phone) + "/"},
		{"server", "fipsmesh://" + key.Npub + "/"},
	}})
	src.src = "vault"
	r = d.Report(context.Background())
	if !r.Box.Approved || len(r.Devices) != 2 || !r.Devices[1].This || r.Hint != "" || r.Source != "vault" {
		t.Fatalf("listed: %+v", r)
	}
	// Screens' fields: listed = approved; only this box has a known role.
	if !r.Devices[0].Approved || !r.Devices[1].Approved || r.Devices[1].Role != "homeVault" || r.Devices[0].Role != "" {
		t.Fatalf("devices shape %+v", r.Devices)
	}

	// Revoked: the newest list no longer names the box.
	src.ev = owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now() + 1, Tags: nostr.Tags{
		{"server", "fipsmesh://" + npubOf(t, phone) + "/"},
	}})
	r = d.Report(context.Background())
	if r.Box.Approved {
		t.Fatalf("revoked box still approved: %+v", r)
	}
}

func TestDevicesReportIsCached(t *testing.T) {
	key, _ := LoadOrCreateDeviceKey(t.TempDir())
	src := &fakeLists{}
	d := &Devices{OwnerHex: newTestKey(t).pk, Key: key, Source: src}
	d.Report(context.Background())
	d.Report(context.Background())
	if src.calls != 1 {
		t.Fatalf("source asked %d times", src.calls)
	}
}

func TestValidServerList(t *testing.T) {
	owner, other := newTestKey(t), newTestKey(t)
	good := owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now()})
	if !validServerList(good, owner.pk) {
		t.Fatal("good list refused")
	}
	if validServerList(other.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now()}), owner.pk) {
		t.Fatal("someone else's list accepted")
	}
	if validServerList(owner.sign(t, nostr.Event{Kind: 10002, CreatedAt: nostr.Now()}), owner.pk) {
		t.Fatal("wrong kind accepted")
	}
	if validServerList(owner.sign(t, nostr.Event{Kind: 10063, CreatedAt: nostr.Now() + 3600}), owner.pk) {
		t.Fatal("future list accepted")
	}
	forged := *good
	forged.Tags = nostr.Tags{{"server", "fipsmesh://x/"}}
	if validServerList(&forged, owner.pk) {
		t.Fatal("tampered list accepted")
	}
}
