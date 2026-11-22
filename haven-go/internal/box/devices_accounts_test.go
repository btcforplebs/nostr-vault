package box

import (
	"context"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// perKeyLists answers each account's own list.
type perKeyLists map[string]*nostr.Event

func (p perKeyLists) Newest(_ context.Context, pk string) (*nostr.Event, string) {
	if ev := p[pk]; ev != nil {
		return ev, "vault"
	}
	return nil, "none"
}

func serverList(t *testing.T, k testKey, at nostr.Timestamp, npubs ...string) *nostr.Event {
	tags := nostr.Tags{}
	for _, n := range npubs {
		tags = append(tags, nostr.Tag{"server", "fipsmesh://" + n + "/"})
	}
	return k.sign(t, nostr.Event{Kind: 10063, CreatedAt: at, Tags: tags})
}

func TestDevicesFromEverySignedInAccount(t *testing.T) {
	owner, signed, watch := newTestKey(t), newTestKey(t), newTestKey(t)
	boxKey, ownerPhone, signedPhone, watchPhone := newTestKey(t), newTestKey(t), newTestKey(t), newTestKey(t)
	nBox := npubOf(t, boxKey)
	now := nostr.Now()
	src := perKeyLists{
		// The first account has not approved the box at all.
		owner.pk:  serverList(t, owner, now, npubOf(t, ownerPhone)),
		signed.pk: serverList(t, signed, now, nBox, npubOf(t, signedPhone), npubOf(t, ownerPhone)),
		// A watch-only key lists the box and its own phone: never counted.
		watch.pk: serverList(t, watch, now, nBox, npubOf(t, watchPhone)),
	}
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	counted := []string{owner.pk, signed.pk}
	d := &Devices{OwnerHex: owner.pk, Accounts: func() []string { return counted }, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file}

	r := d.Refresh(context.Background())
	if !r.Box.Approved || r.Hint != "" {
		t.Fatalf("box approved by a signed-in account's list: %+v", r.Box)
	}
	got := readDevicesFile(t, file)
	slices.Sort(got)
	want := []string{npubOf(t, ownerPhone), npubOf(t, signedPhone)}
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("mesh devices = %v, want %v (and never the watch-only phone)", got, want)
	}
	for _, e := range r.Devices {
		switch e.Npub {
		case npubOf(t, ownerPhone):
			if !slices.Equal(e.VouchedBy, []string{npubOf(t, owner), npubOf(t, signed)}) {
				t.Errorf("owner phone vouched by %v", e.VouchedBy)
			}
		case npubOf(t, signedPhone):
			if !slices.Equal(e.VouchedBy, []string{npubOf(t, signed)}) {
				t.Errorf("signed phone vouched by %v", e.VouchedBy)
			}
		case npubOf(t, watchPhone):
			t.Error("the watch-only account's phone is listed")
		}
	}
	if len(r.Lists) != 2 || !r.Lists[0].First || r.ListID != src[owner.pk].ID {
		t.Fatalf("lists %+v, first list %s", r.Lists, r.ListID)
	}

	// The signed-in account's list can't be read now: its devices stay.
	delete(src, signed.pk)
	d.Refresh(context.Background())
	if got := readDevicesFile(t, file); len(got) != 2 {
		t.Fatalf("an unreadable list dropped devices: %v", got)
	}

	// Removed (no longer counted): its vouching goes, and with it the box's
	// approval, so nothing is let in.
	src[signed.pk] = serverList(t, signed, now, nBox, npubOf(t, signedPhone))
	counted = []string{owner.pk}
	r = d.Refresh(context.Background())
	if r.Box.Approved || len(readDevicesFile(t, file)) != 0 {
		t.Fatalf("a removed account still vouches: approved %v, file %v", r.Box.Approved, readDevicesFile(t, file))
	}
}

func TestAccountStoreReadersAreFirstAndSignedIn(t *testing.T) {
	owner, signed, watch := newTestKey(t), newTestKey(t), newTestKey(t)
	s := &AccountStore{Path: filepath.Join(t.TempDir(), "accounts.json"), OwnerHex: owner.pk, OwnerNpub: npubOf(t, owner)}
	SaveAccounts(s.Path, []Account{{Npub: npubOf(t, watch)}, {Npub: npubOf(t, signed), SignedIn: true}})
	if got := s.Readers(); !slices.Equal(got, []string{owner.pk, signed.pk}) {
		t.Fatalf("Readers = %v", got)
	}
}

// Tron #2376: the first account has no list, a signed-in account approved
// the box and its phone. Removing that account must empty the file at once,
// though no list is left to write from.
func TestRemovingTheOnlyVouchingAccountShutsItsDevicesOut(t *testing.T) {
	owner, signed := newTestKey(t), newTestKey(t)
	boxKey, phone := newTestKey(t), newTestKey(t)
	src := perKeyLists{signed.pk: serverList(t, signed, nostr.Now(), npubOf(t, boxKey), npubOf(t, phone))}
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	counted := []string{owner.pk, signed.pk}
	d := &Devices{OwnerHex: owner.pk, Accounts: func() []string { return counted }, Mesh: testMeshID(t, boxKey), Source: src, DevicesFile: file}

	d.Refresh(context.Background())
	if got := readDevicesFile(t, file); !slices.Equal(got, []string{npubOf(t, phone)}) {
		t.Fatalf("before removal: %v", got)
	}
	counted = []string{owner.pk}
	d.Refresh(context.Background())
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("a removed account's phone is still let in: %v", got)
	}
	// Still no list at all: the next read leaves the (now empty) file alone.
	d.Refresh(context.Background())
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("after removal: %v", got)
	}
}

// slowLists answers after delay, so asking N accounts in turn would take N
// delays.
type slowLists struct{ delay time.Duration }

func (s slowLists) Newest(ctx context.Context, _ string) (*nostr.Event, string) {
	time.Sleep(s.delay)
	return nil, "none"
}

func TestDevicesAskEveryAccountAtOnce(t *testing.T) {
	keys := []string{}
	for i := 0; i < 5; i++ {
		keys = append(keys, newTestKey(t).pk)
	}
	d := &Devices{OwnerHex: keys[0], Accounts: func() []string { return keys }, Mesh: testMeshID(t, newTestKey(t)), Source: slowLists{200 * time.Millisecond}}
	start := time.Now()
	d.Refresh(context.Background())
	if took := time.Since(start); took > 600*time.Millisecond {
		t.Fatalf("5 accounts took %v; want about one answer's time", took)
	}
}

// gatedLists answers at once, except for one key, whose answer waits for
// release.
type gatedLists struct {
	perKeyLists
	slow    string
	entered chan struct{}
	release chan struct{}
}

func (g gatedLists) Newest(ctx context.Context, pk string) (*nostr.Event, string) {
	if pk == g.slow {
		close(g.entered)
		<-g.release
	}
	return g.perKeyLists.Newest(ctx, pk)
}

// Tron #2376: a poll already fetching when an account is removed must not
// put its list, and its phone, back after the removal's read.
func TestASlowReadCannotBringARemovedAccountBack(t *testing.T) {
	owner, signed := newTestKey(t), newTestKey(t)
	boxKey, phone := newTestKey(t), newTestKey(t)
	lists := perKeyLists{signed.pk: serverList(t, signed, nostr.Now(), npubOf(t, boxKey), npubOf(t, phone))}
	file := filepath.Join(t.TempDir(), "mesh-devices.json")
	var mu sync.Mutex
	counted := []string{owner.pk, signed.pk}
	accounts := func() []string { mu.Lock(); defer mu.Unlock(); return slices.Clone(counted) }
	d := &Devices{OwnerHex: owner.pk, Accounts: accounts, Mesh: testMeshID(t, boxKey), Source: lists, DevicesFile: file}
	d.Refresh(context.Background())

	g := gatedLists{lists, signed.pk, make(chan struct{}), make(chan struct{})}
	done := make(chan struct{})
	go func() { d.read(context.Background(), g.Newest); close(done) }()
	<-g.entered // the poll is fetching the signed-in account's list

	mu.Lock()
	counted = []string{owner.pk}
	mu.Unlock()
	d.Refresh(context.Background()) // the removal's read
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("after removal: %v", got)
	}
	close(g.release)
	<-done
	if got := readDevicesFile(t, file); len(got) != 0 {
		t.Fatalf("the slow poll let the removed account's phone back in: %v", got)
	}
}
