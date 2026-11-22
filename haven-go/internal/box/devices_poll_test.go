package box

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// listRelay is a local relay that serves one owner's kind 10063 (or none)
// and counts the connections made to it. Throwaway keys only.
type listRelay struct {
	url   string
	dials atomic.Int32
	mu    sync.Mutex
	ev    *nostr.Event
}

func newListRelay(t *testing.T) *listRelay {
	t.Helper()
	lr := &listRelay{}
	r := khatru.NewRelay()
	r.OnConnect = append(r.OnConnect, func(context.Context) { lr.dials.Add(1) })
	r.QueryEvents = append(r.QueryEvents, func(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
		ch := make(chan *nostr.Event, 1)
		lr.mu.Lock()
		if lr.ev != nil {
			ch <- lr.ev
		}
		lr.mu.Unlock()
		close(ch)
		return ch, nil
	})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	lr.url = "ws" + strings.TrimPrefix(srv.URL, "http")
	return lr
}

func (lr *listRelay) set(ev *nostr.Event) { lr.mu.Lock(); lr.ev = ev; lr.mu.Unlock() }

func signedList(t *testing.T, owner testKey, at int64) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: 10063, CreatedAt: nostr.Timestamp(at), Tags: nostr.Tags{{"server", "https://blossom.example/"}}}
	if err := ev.Sign(owner.sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func TestPollAsksOnlyTheVaultWhileItHasTheNewestList(t *testing.T) {
	owner := newTestKey(t)
	vault, dirA, dirB := newListRelay(t), newListRelay(t), newListRelay(t)
	now := time.Now().Unix()
	list := signedList(t, owner, now-100)
	vault.set(list)
	dirA.set(list)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dirA.url, dirB.url}, DirectoryEvery: time.Hour}
	ctx := context.Background()

	ev, src := s.Poll(ctx, owner.pk) // first poll: the directory has never been asked
	if ev == nil || ev.ID != list.ID || src != "vault" {
		t.Fatalf("first poll: %v %s", ev, src)
	}
	for i := 0; i < 5; i++ {
		if ev, _ := s.Poll(ctx, owner.pk); ev == nil || ev.ID != list.ID {
			t.Fatalf("poll %d lost the list", i)
		}
	}
	if v, a, b := vault.dials.Load(), dirA.dials.Load(), dirB.dials.Load(); v != 6 || a != 1 || b != 1 {
		t.Fatalf("dials vault %d, directory %d + %d; want 6, 1, 1", v, a, b)
	}
}

func TestPollAsksTheDirectoryWhenTheVaultHasNoList(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	list := signedList(t, owner, time.Now().Unix()-100)
	dir.set(list)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}, DirectoryEvery: time.Hour}
	for i := 0; i < 3; i++ {
		if ev, src := s.Poll(context.Background(), owner.pk); ev == nil || src != "relays" {
			t.Fatalf("poll %d: %v %s", i, ev, src)
		}
	}
	if d := dir.dials.Load(); d != 3 {
		t.Fatalf("directory dialled %d times; want every poll while the vault has nothing", d)
	}
}

// The phone may publish a new list to the relays and not to the box: once
// the directory shows a newer list than the vault, it is asked on every poll
// until the vault catches up, so an approval is never 10 minutes late twice.
func TestPollKeepsAskingTheDirectoryWhileTheVaultLags(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	now := time.Now().Unix()
	old, newer := signedList(t, owner, now-200), signedList(t, owner, now-100)
	vault.set(old)
	dir.set(newer)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}, DirectoryEvery: time.Hour}
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		if ev, src := s.Poll(ctx, owner.pk); ev == nil || ev.ID != newer.ID || src != "relays" {
			t.Fatalf("poll %d: %v %s", i, ev, src)
		}
	}
	if d := dir.dials.Load(); d != 3 {
		t.Fatalf("directory dialled %d times while ahead of the vault; want 3", d)
	}
	vault.set(newer) // caught up: back to the vault alone
	s.Poll(ctx, owner.pk)
	s.Poll(ctx, owner.pk)
	s.Poll(ctx, owner.pk)
	if d := dir.dials.Load(); d != 4 {
		t.Fatalf("directory dialled %d times after the vault caught up; want one more check then none", d)
	}
}

func TestPollAsksTheDirectoryAgainOnceDue(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	list := signedList(t, owner, time.Now().Unix()-100)
	vault.set(list)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}, DirectoryEvery: 50 * time.Millisecond}
	ctx := context.Background()
	s.Poll(ctx, owner.pk)
	s.Poll(ctx, owner.pk)
	time.Sleep(60 * time.Millisecond)
	s.Poll(ctx, owner.pk)
	if d := dir.dials.Load(); d != 2 {
		t.Fatalf("directory dialled %d times; want the first poll and once more when due", d)
	}
}

func TestNewestStillAsksEveryRelay(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	now := time.Now().Unix()
	vault.set(signedList(t, owner, now-100))
	newer := signedList(t, owner, now-50)
	dir.set(newer)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}}
	for i := 0; i < 2; i++ {
		if ev, src := s.Newest(context.Background(), owner.pk); ev == nil || ev.ID != newer.ID || src != "relays" {
			t.Fatalf("newest: %v %s", ev, src)
		}
	}
	if v, d := vault.dials.Load(), dir.dials.Load(); v != 2 || d != 2 {
		t.Fatalf("the devices screen asks everyone: vault %d, directory %d", v, d)
	}
}

type pollingLists struct {
	fakeLists
	polls int
}

func (p *pollingLists) Poll(ctx context.Context, owner string) (*nostr.Event, string) {
	p.polls++
	return p.ev, p.src
}

func TestRunUsesPollAndTheScreenUsesNewest(t *testing.T) {
	owner, boxKey := newTestKey(t), newTestKey(t)
	src := &pollingLists{}
	d := &Devices{OwnerHex: owner.pk, Mesh: testMeshID(t, boxKey), Source: src, TTL: time.Nanosecond}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Millisecond)
	defer cancel()
	d.Run(ctx, 10*time.Millisecond)
	d.Report(context.Background())
	if src.polls < 2 || src.calls != 1 {
		t.Fatalf("polls %d, newest %d: Run polls, the screen asks everyone", src.polls, src.calls)
	}
}

// Tron #2376: a signed-in account that never made a 10063 has none in the
// vault or on the directory. After one empty directory answer, the
// directory waits until due, not every 30 s poll.
func TestPollBacksOffTheDirectoryWhenNobodyHasAList(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}, DirectoryEvery: time.Hour}
	ctx := context.Background()
	for i := 0; i < 4; i++ {
		if ev, _ := s.Poll(ctx, owner.pk); ev != nil {
			t.Fatalf("poll %d found a list", i)
		}
	}
	if d := dir.dials.Load(); d != 1 {
		t.Fatalf("directory dialled %d times for an account with no list; want 1", d)
	}
	// The list then appears on the directory only: found once due.
	dir.set(signedList(t, owner, time.Now().Unix()-10))
	s.mu.Lock()
	s.dirAt[owner.pk] = time.Now().Add(-2 * time.Hour)
	s.mu.Unlock()
	if ev, src := s.Poll(ctx, owner.pk); ev == nil || src != "relays" {
		t.Fatalf("due poll: %v %s", ev, src)
	}
}

// The first account is never backed off: on a new box the first approval
// may reach only the directory relays (Tron #2376 note).
func TestPollNeverBacksOffTheFirstAccount(t *testing.T) {
	owner := newTestKey(t)
	vault, dir := newListRelay(t), newListRelay(t)
	s := &RelayServerLists{VaultURL: vault.url, Directory: []string{dir.url}, DirectoryEvery: time.Hour, First: owner.pk}
	for i := 0; i < 3; i++ {
		s.Poll(context.Background(), owner.pk)
	}
	if d := dir.dials.Load(); d != 3 {
		t.Fatalf("directory dialled %d times for the first account with no list; want every poll", d)
	}
}
