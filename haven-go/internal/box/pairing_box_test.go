package box

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// fakePairCrypto stands in for nv-mesh: the "sealed" content is the plain
// hello, the sender is the event's signer. It records what it was asked to
// seal as the ack.
type fakePairCrypto struct {
	mu     sync.Mutex
	acks   []string
	ackTo  []string
	broken bool
}

func (f *fakePairCrypto) PairOpen(_ context.Context, ev *nostr.Event) (string, string, error) {
	if f.broken {
		return "", "", errors.New("nv-mesh's dial socket: away")
	}
	return ev.PubKey, ev.Content, nil
}

func (f *fakePairCrypto) PairAck(_ context.Context, to, content string) (*nostr.Event, error) {
	if f.broken {
		return nil, errors.New("nv-mesh's dial socket: away")
	}
	f.mu.Lock()
	f.acks, f.ackTo = append(f.acks, content), append(f.ackTo, to)
	f.mu.Unlock()
	return &nostr.Event{Kind: PairHelloKind, Content: content, Tags: nostr.Tags{{"p", npubHex(to)}}}, nil
}

// fakeRelays hands Listen the events pushed on in, and counts publishes.
type fakeRelays struct {
	in        chan *nostr.Event
	mu        sync.Mutex
	published []*nostr.Event
	listening chan struct{}
	took      int // relays that take a publish; 0 reads as 2, -1 as none
}

func newFakeRelays() *fakeRelays {
	return &fakeRelays{in: make(chan *nostr.Event, 8), listening: make(chan struct{}, 8)}
}

func (f *fakeRelays) Listen(ctx context.Context, _ string, _ int64, onEvent func(*nostr.Event)) {
	f.listening <- struct{}{}
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-f.in:
			onEvent(ev)
		}
	}
}

func (f *fakeRelays) Publish(_ context.Context, ev *nostr.Event) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.published = append(f.published, ev)
	if f.took < 0 {
		return 0
	}
	return 2
}

// pairingAPI is newTestAPI with pairing on a clock the test moves.
// NIP-98 proofs are one-use, and the same request twice in one second is the
// same event: repeated calls in these tests carry a nonce in the body.
func pairingAPI(t *testing.T) (*httptest.Server, testKey, *API, *fakePairCrypto, *fakeRelays, *atomic.Int64) {
	t.Helper()
	srv, owner, api := newTestAPI(t)
	now := &atomic.Int64{} // the listen goroutine reads it while tests move it
	now.Store(time.Now().Unix())
	crypto, relays := &fakePairCrypto{}, newFakeRelays()
	api.Pairing = &Pairing{
		Mesh: api.Mesh, Crypto: crypto, Relays: relays,
		Paired:   &PairedSet{Path: filepath.Join(t.TempDir(), "paired-devices.json")},
		Accounts: func() []string { return []string{owner.pk} },
		Now:      now.Load,
	}
	return srv, owner, api, crypto, relays, now
}

func pairStatus(t *testing.T, srv *httptest.Server, k testKey, method, path string, body []byte) (int, PairStatus) {
	t.Helper()
	st, out := call(t, srv, &k, method, path, body)
	raw, _ := json.Marshal(out)
	var ps PairStatus
	if p, ok := out["pairing"]; ok {
		raw, _ = json.Marshal(p)
	}
	json.Unmarshal(raw, &ps)
	return st, ps
}

func helloEvent(t *testing.T, phone testKey, secret, name, role, owner string, at int64) *nostr.Event {
	t.Helper()
	return phone.sign(t, nostr.Event{Kind: PairHelloKind, CreatedAt: nostr.Timestamp(at), Content: PairHelloJSON(secret, name, role, owner, at)})
}

func waitState(t *testing.T, srv *httptest.Server, k testKey, want string) PairStatus {
	t.Helper()
	var ps PairStatus
	for i := 0; i < 100; i++ {
		_, ps = pairStatus(t, srv, k, "GET", "/api/box/pair", nil)
		if ps.State == want {
			return ps
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("state %q, want %q: %+v", ps.State, want, ps)
	return ps
}

func TestBoxPairingHappyPathStoresAndAcksWithTheWords(t *testing.T) {
	srv, owner, api, crypto, relays, now := pairingAPI(t)
	phone := newTestKey(t)
	ownerNpub := npubOf(t, owner)

	st, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	if st != 200 || ps.State != "waiting" || ps.Code == "" || ps.ExpiresAt != now.Load()+pairCodeLifetime {
		t.Fatalf("start: %d %+v", st, ps)
	}
	code, refusal := ParsePairCode(ps.Code, "")
	if refusal != "" || code.Mesh != meshNpub(t, api.Mesh) || code.Role != "homeVault" || code.Owner != ownerNpub || code.Name != "Nostr Vault box" || code.Secret == "" {
		t.Fatalf("code %+v (%s): the box shows itself as the home vault for the caller's account", code, refusal)
	}
	<-relays.listening

	// A stranger's hello (another account) is refused and does not abort;
	// garbage is ignored; then the owner's phone says hello.
	relays.in <- helloEvent(t, newTestKey(t), code.Secret, "Not yours", "phone", npubOf(t, newTestKey(t)), now.Load()+5)
	relays.in <- &nostr.Event{Kind: 1, Content: "hi"}
	relays.in <- helloEvent(t, phone, code.Secret, "Logen's iPhone", "phone", ownerNpub, now.Load()+10)
	now.Add(12)
	ps = waitState(t, srv, owner, "hello")
	if ps.Device == nil || ps.Device.Npub != npubOf(t, phone) || ps.Device.Name != "Logen's iPhone" || ps.Device.Role != "phone" {
		t.Fatalf("device %+v", ps.Device)
	}
	if ps.Refusal != "otherOwner" {
		t.Fatalf("refusal %q: the stranger's hello should show, and not abort", ps.Refusal)
	}
	if len(ps.Words) != 4 || ps.ConfirmText != "Add Logen's iPhone as another of your phones." || ps.Code != "" {
		t.Fatalf("hello status %+v", ps)
	}
	_, boxHex, _ := api.Mesh.Read()
	if want := PairCheckWordIndexes(boxHex, phone.pk, code.Secret); !slices.Equal(ps.Words, want) {
		t.Fatalf("words %v, want %v", ps.Words, want)
	}

	// Confirm must carry the role shown (a phone is never added as a vault).
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"homeVault"}`)); st != 409 {
		t.Fatalf("confirm with another role: %d", st)
	}
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{}`)); st != 400 {
		t.Fatalf("confirm with no role: %d", st)
	}
	st, ps = pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`))
	if st != 200 || ps.State != "linked" || ps.Acked != 2 {
		t.Fatalf("confirm: %d %+v", st, ps)
	}
	// Stored, with who confirmed it and the hello's name and role.
	list, _ := api.Pairing.Paired.List()
	if len(list) != 1 || list[0].Npub != npubOf(t, phone) || list[0].Role != "phone" || list[0].Name != "Logen's iPhone" || list[0].By != ownerNpub || list[0].From != "pair" {
		t.Fatalf("paired = %+v", list)
	}
	// The ack is the check-words form (the box has no camera), sealed to
	// the phone and sent once.
	if len(crypto.acks) != 1 || crypto.ackTo[0] != npubOf(t, phone) {
		t.Fatalf("acks %v to %v", crypto.acks, crypto.ackTo)
	}
	want := PairAckJSON(PairAckDigest(code.Secret, boxHex, phone.pk, ""), true)
	if crypto.acks[0] != want {
		t.Fatalf("ack\n got %s\nwant %s", crypto.acks[0], want)
	}
	if len(relays.published) != 1 || relays.published[0].Content != want {
		t.Fatalf("published %d", len(relays.published))
	}
	// The code is spent: a second confirm has nothing to add, and a late
	// hello changes nothing.
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone","again":1}`)); st != 409 {
		t.Fatalf("second confirm: %d", st)
	}
	if out := api.Pairing.Hello(context.Background(), api.Pairing.run, helloEvent(t, newTestKey(t), code.Secret, "x", "phone", ownerNpub, now.Load())); out != "ignoreDuplicate" {
		t.Fatalf("hello after linking: %s", out)
	}
	if _, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair/cancel", nil); ps.State != "idle" {
		t.Fatalf("cancel: %+v", ps)
	}
}

func TestBoxPairingRefusesBeforeAHelloAndExpires(t *testing.T) {
	srv, owner, api, _, relays, now := pairingAPI(t)
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`)); st != 409 {
		t.Fatalf("confirm with no pairing: %d", st)
	}
	st, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	if st != 200 || ps.State != "waiting" {
		t.Fatalf("start: %d %+v", st, ps)
	}
	<-relays.listening
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone","again":1}`)); st != 409 {
		t.Fatalf("confirm before a hello: %d", st)
	}
	// The code runs out after 3 minutes with no hello; a hello then is too late.
	now.Add(pairCodeLifetime + 1)
	if _, ps := pairStatus(t, srv, owner, "GET", "/api/box/pair", nil); ps.State != "expired" {
		t.Fatalf("after the code's life: %+v", ps)
	}
	code, _ := ParsePairCode(ps.Code, "")
	out := api.Pairing.Hello(context.Background(), api.Pairing.run, helloEvent(t, newTestKey(t), code.Secret, "late", "phone", npubOf(t, owner), now.Load()))
	if out != "stop" {
		t.Fatalf("late hello: %s", out)
	}
	if n, _ := api.Pairing.Paired.Npubs(); len(n) != 0 {
		t.Fatal("something was stored")
	}
	// A new code replaces the old one.
	if _, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", []byte(`{"again":1}`)); ps.State != "waiting" || strings.Contains(ps.Code, code.Secret) {
		t.Fatalf("restart: %+v", ps)
	}
}

func TestBoxPairingSecondDeviceAbortsAndMeshAwayStoresNothing(t *testing.T) {
	srv, owner, api, crypto, relays, now := pairingAPI(t)
	ownerNpub := npubOf(t, owner)
	_, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	code, _ := ParsePairCode(ps.Code, "")
	<-relays.listening
	relays.in <- helloEvent(t, newTestKey(t), code.Secret, "one", "phone", ownerNpub, now.Load())
	waitState(t, srv, owner, "hello")
	// Another device with the same secret: the code was shown to two devices.
	relays.in <- helloEvent(t, newTestKey(t), code.Secret, "two", "phone", ownerNpub, now.Load())
	ps = waitState(t, srv, owner, "aborted")
	if ps.Refusal != "abort" {
		t.Fatalf("%+v", ps)
	}
	if st, _ := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`)); st != 409 {
		t.Fatalf("confirm after abort: %d", st)
	}

	// nv-mesh away at confirm time: nothing stored, the error shows.
	_, ps = pairStatus(t, srv, owner, "POST", "/api/box/pair", nil)
	code, _ = ParsePairCode(ps.Code, "")
	<-relays.listening
	phone := newTestKey(t)
	relays.in <- helloEvent(t, phone, code.Secret, "Logen's iPhone", "phone", ownerNpub, now.Load())
	waitState(t, srv, owner, "hello")
	crypto.broken = true
	st, ps := pairStatus(t, srv, owner, "POST", "/api/box/pair/confirm", []byte(`{"role":"phone"}`))
	if st != 503 || ps.State != "expired" || ps.Error == "" {
		t.Fatalf("confirm with the mesh away: %d %+v", st, ps)
	}
	if n, _ := api.Pairing.Paired.Npubs(); len(n) != 0 || len(relays.published) != 0 {
		t.Fatal("stored or published with the mesh away")
	}
}

func TestBoxPairingNeedsAMeshKeyAndASignedInCaller(t *testing.T) {
	srv, owner, api, _, _, _ := pairingAPI(t)
	api.Pairing.Mesh = MeshID{NpubFile: filepath.Join(t.TempDir(), "none")}
	if st, _ := call(t, srv, &owner, "POST", "/api/box/pair", nil); st != 503 {
		t.Fatalf("no mesh key: %d", st)
	}
	stranger := newTestKey(t)
	for _, r := range []struct{ m, p string }{{"GET", "/api/box/pair"}, {"POST", "/api/box/pair"}, {"POST", "/api/box/pair/confirm"}, {"POST", "/api/box/pair/cancel"}} {
		if st, _ := call(t, srv, &stranger, r.m, r.p, []byte(`{"role":"phone"}`)); st != 403 {
			t.Errorf("%s %s by a stranger: %d", r.m, r.p, st)
		}
	}
	api.Pairing = nil
	if st, _ := call(t, srv, &owner, "GET", "/api/box/pair", nil); st != 503 {
		t.Fatalf("no pairing wired: %d", st)
	}
}

func TestFinderRelaysFromEnv(t *testing.T) {
	env := map[string]string{"NV_DATA_DIR": "/data", "NV_OWNER": npubOf(t, newTestKey(t))}
	c, err := ConfigFromEnv(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(c.FinderRelays, ",") != strings.Join(DefaultFinderRelays, ",") {
		t.Fatalf("default finder relays %v", c.FinderRelays)
	}
	env["NV_MESH_RELAYS"] = " wss://a.example , wss://b.example,"
	c, _ = ConfigFromEnv(func(k string) string { return env[k] })
	if strings.Join(c.FinderRelays, ",") != "wss://a.example,wss://b.example" {
		t.Fatalf("finder relays %v", c.FinderRelays)
	}
}
