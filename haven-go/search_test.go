//go:build !cshared

package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/pkg/wot"
)

func TestParseSearchTerms(t *testing.T) {
	got := parseSearchTerms("  Bitcoin  CONFERENCE include:spam language:en https://x.org ")
	want := []string{"bitcoin", "conference", "https://x.org"}
	if !slices.Equal(got, want) {
		t.Fatalf("terms = %q, want %q", got, want)
	}
	if got := parseSearchTerms("include:spam  "); len(got) != 0 {
		t.Fatalf("extension-only query must have no terms, got %q", got)
	}
}

func TestEventMatchesSearch(t *testing.T) {
	profile := &nostr.Event{Kind: 0, Content: `{"name":"Satoshi","display_name":"Nakamoto","about":"Hal's friend","nip05":"sn@example.com","picture":"https://img.example/nashville.png"}`}
	cases := []struct {
		name  string
		ev    *nostr.Event
		query string
		want  bool
	}{
		{"all terms any case", &nostr.Event{Kind: 1, Content: "Bitcoin conference in Nashville"}, "NASHVILLE bitcoin", true},
		{"one term missing", &nostr.Event{Kind: 1, Content: "Bitcoin only"}, "bitcoin conference", false},
		{"kind 0 name", profile, "satoshi", true},
		{"kind 0 display_name + about", profile, "nakamoto hal's", true},
		{"kind 0 nip05", profile, "sn@example.com", true},
		{"kind 0 picture url is not text", profile, "nashville", false},
		{"kind 0 json key is not text", profile, "picture", false},
		{"kind 0 invalid json", &nostr.Event{Kind: 0, Content: "satoshi"}, "satoshi", false},
		{"gift wrap ciphertext skipped", &nostr.Event{Kind: 1059, Content: "abcdef"}, "abc", false},
		{"dm ciphertext skipped", &nostr.Event{Kind: 4, Content: "abcdef?iv=x"}, "abc", false},
		{"long-form title tag", &nostr.Event{Kind: 30023, Content: "body", Tags: nostr.Tags{{"title", "Sovereign Relays"}}}, "sovereign", true},
		{"no terms matches nothing", &nostr.Event{Kind: 1, Content: "anything"}, "include:spam", false},
	}
	for _, c := range cases {
		if got := eventMatchesSearch(c.ev, parseSearchTerms(c.query)); got != c.want {
			t.Errorf("%s: match(%q) = %v, want %v", c.name, c.query, got, c.want)
		}
	}
}

// signedAt signs a note of the given kind/content at a fixed time.
func signedAt(t testing.TB, sk string, kind int, content string, at int64) *nostr.Event {
	t.Helper()
	ev := &nostr.Event{Kind: kind, Content: content, CreatedAt: nostr.Timestamp(at), Tags: nostr.Tags{}}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	return ev
}

func saveAll(t testing.TB, db DBBackend, evs ...*nostr.Event) {
	t.Helper()
	for _, ev := range evs {
		if err := db.SaveEvent(context.Background(), ev); err != nil {
			t.Fatal(err)
		}
	}
}

func idSet(evs []*nostr.Event) map[string]bool {
	m := make(map[string]bool, len(evs))
	for _, ev := range evs {
		m[ev.ID] = true
	}
	return m
}

// havenUnderTest boots the real initRelays (every route, its real read
// policies) on Badger stores in a temp dir, served through
// dynamicRelayHandler exactly as the app serves them.
type havenUnderTest struct {
	base    string // ws://127.0.0.1:port
	ownerSK string
	owner   string
}

func startHaven(t *testing.T) *havenUnderTest {
	t.Helper()
	t.Chdir(t.TempDir())

	ownerSK := nostr.GeneratePrivateKey()
	owner, _ := nostr.GetPublicKey(ownerSK)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	prevConfig, prevFs := config, fs
	config = Config{
		DBEngine:           "badger",
		RelayPort:          port,
		WhitelistedPubKeys: map[string]struct{}{owner: {}},
		BlacklistedPubKeys: map[string]struct{}{},
		BlossomPath:        "blossom/",
	}
	fs = afero.NewMemMapFs()
	wot.MarkReady(wot.NewCycle(), stubWot{members: map[string]bool{owner: true}})

	ctx, cancel := context.WithCancel(context.Background())
	if err := initRelays(ctx); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(dynamicRelayHandler))
	srv.Listener.Close()
	srv.Listener = ln
	srv.Start()
	t.Cleanup(func() {
		srv.Close()
		cancel()
		CloseDBs()
		config, fs = prevConfig, prevFs
	})
	return &havenUnderTest{base: fmt.Sprintf("ws://127.0.0.1:%d", port), ownerSK: ownerSK, owner: owner}
}

func (h *havenUnderTest) connect(t *testing.T, path string) *nostr.Relay {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, err := nostr.RelayConnect(ctx, h.base+path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

// req runs one REQ to EOSE or CLOSED and returns the events plus the CLOSED
// reason ("" when the subscription reached EOSE).
func req(t *testing.T, r *nostr.Relay, f nostr.Filter) ([]*nostr.Event, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sub, err := r.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsub()
	var out []*nostr.Event
	for {
		select {
		case ev := <-sub.Events:
			out = append(out, ev)
		case <-sub.EndOfStoredEvents:
			// drain anything already queued behind EOSE
			for {
				select {
				case ev := <-sub.Events:
					out = append(out, ev)
				default:
					return out, ""
				}
			}
		case reason := <-sub.ClosedReason:
			return out, reason
		case <-ctx.Done():
			t.Fatalf("REQ %v timed out", f)
		}
	}
}

func TestSearchRoutes(t *testing.T) {
	h := startHaven(t)
	now := time.Now().Unix()
	otherSK := nostr.GeneratePrivateKey()
	other, _ := nostr.GetPublicKey(otherSK)

	both1 := signedAt(t, h.ownerSK, 1, "Bitcoin conference in Nashville", now-100)
	both2 := signedAt(t, otherSK, 1, "the CONFERENCE was about bitcoin", now-200)
	onlyA := signedAt(t, h.ownerSK, 1, "bitcoin only", now-300)
	onlyB := signedAt(t, h.ownerSK, 1, "conference only", now-400)
	profile := signedAt(t, h.ownerSK, 0, `{"name":"Satoshi","about":"likes bitcoin","picture":"https://img.example/conference.png"}`, now-500)
	var lorem []*nostr.Event
	for i := 0; i < 30; i++ {
		lorem = append(lorem, signedAt(t, h.ownerSK, 1, fmt.Sprintf("lorem ipsum %d", i), now-1000-int64(i)*10))
	}
	saveAll(t, outboxDB, both1, both2, onlyA, onlyB, profile)
	saveAll(t, outboxDB, lorem...)
	secret := signedAt(t, h.ownerSK, 1, "secret launch plan", now-50)
	saveAll(t, privateDB, secret)
	saveAll(t, chatDB, signedAt(t, h.ownerSK, nostr.KindSimpleGroupChatMessage, "secret chat", now-50))

	outbox := h.connect(t, "")

	t.Run("all terms, any case, nothing else", func(t *testing.T) {
		got, closed := req(t, outbox, nostr.Filter{Kinds: []int{1}, Search: "BITCOIN Conference"})
		if closed != "" {
			t.Fatalf("closed: %s", closed)
		}
		ids := idSet(got)
		if len(got) != 2 || !ids[both1.ID] || !ids[both2.ID] {
			t.Fatalf("got %d events %v, want exactly both1+both2", len(got), got)
		}
		// newest first
		if got[0].ID != both1.ID {
			t.Fatalf("want newest first, got %s first", got[0].Content)
		}
	})

	t.Run("no match returns nothing, not the store", func(t *testing.T) {
		got, closed := req(t, outbox, nostr.Filter{Kinds: []int{1}, Search: "zzzunmatched"})
		if closed != "" || len(got) != 0 {
			t.Fatalf("want 0 events at EOSE, got %d (closed=%q)", len(got), closed)
		}
		got, _ = req(t, outbox, nostr.Filter{Kinds: []int{1}, Search: "include:spam"})
		if len(got) != 0 {
			t.Fatalf("extension-only search returned %d events", len(got))
		}
	})

	t.Run("kind 0 matches profile text, not json or urls", func(t *testing.T) {
		got, _ := req(t, outbox, nostr.Filter{Kinds: []int{0}, Search: "satoshi"})
		if len(got) != 1 || got[0].ID != profile.ID {
			t.Fatalf("satoshi: got %v", got)
		}
		got, _ = req(t, outbox, nostr.Filter{Kinds: []int{0}, Search: "conference"})
		if len(got) != 0 {
			t.Fatalf("picture URL matched: %v", got)
		}
		// kinds 0 and 1 together
		got, _ = req(t, outbox, nostr.Filter{Kinds: []int{0, 1}, Search: "bitcoin"})
		ids := idSet(got)
		for _, want := range []*nostr.Event{both1, both2, onlyA, profile} {
			if !ids[want.ID] {
				t.Fatalf("kinds 0+1 bitcoin missing %q", want.Content)
			}
		}
		if len(got) != 4 {
			t.Fatalf("kinds 0+1 bitcoin: got %d, want 4", len(got))
		}
	})

	t.Run("limit keeps the newest", func(t *testing.T) {
		got, _ := req(t, outbox, nostr.Filter{Kinds: []int{1}, Search: "lorem", Limit: 5})
		if len(got) != 5 {
			t.Fatalf("limit 5: got %d", len(got))
		}
		for i, ev := range got {
			if ev.ID != lorem[i].ID {
				t.Fatalf("limit 5: position %d is %q, want %q", i, ev.Content, lorem[i].Content)
			}
		}
	})

	t.Run("authors, since, until honoured", func(t *testing.T) {
		got, _ := req(t, outbox, nostr.Filter{Kinds: []int{1}, Authors: []string{other}, Search: "bitcoin"})
		if len(got) != 1 || got[0].ID != both2.ID {
			t.Fatalf("authors: got %v", got)
		}
		since := nostr.Timestamp(now - 150)
		got, _ = req(t, outbox, nostr.Filter{Kinds: []int{1}, Since: &since, Search: "bitcoin"})
		if len(got) != 1 || got[0].ID != both1.ID {
			t.Fatalf("since: got %v", got)
		}
		until := nostr.Timestamp(now - 250)
		got, _ = req(t, outbox, nostr.Filter{Kinds: []int{1}, Until: &until, Search: "bitcoin"})
		if len(got) != 1 || got[0].ID != onlyA.ID {
			t.Fatalf("until: got %v", got)
		}
	})

	t.Run("plain filters unchanged", func(t *testing.T) {
		got, _ := req(t, outbox, nostr.Filter{Kinds: []int{1}, Authors: []string{other}})
		if len(got) != 1 || got[0].ID != both2.ID {
			t.Fatalf("plain filter: got %v", got)
		}
	})

	t.Run("search-only filter is refused", func(t *testing.T) {
		// Refused on the feed route, which allows empty filters; the outbox
		// already refuses it as empty.
		feed := h.connect(t, "/feed")
		got, closed := req(t, feed, nostr.Filter{Search: "bitcoin"})
		if closed == "" || len(got) != 0 {
			t.Fatalf("want CLOSED and no events, got %d events closed=%q", len(got), closed)
		}
	})

	t.Run("COUNT with search is not the unfiltered count", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		n, _, _ := outbox.Count(ctx, nostr.Filters{{Kinds: []int{1}, Search: "zzzunmatched"}})
		if n != 0 {
			t.Fatalf("COUNT with search = %d, want 0", n)
		}
	})

	t.Run("private and chat still need auth", func(t *testing.T) {
		for _, path := range []string{"/private", "/chat"} {
			r := h.connect(t, path)
			got, closed := req(t, r, nostr.Filter{Kinds: []int{1, nostr.KindSimpleGroupChatMessage}, Search: "secret"})
			if len(got) != 0 {
				t.Fatalf("%s: unauthenticated search returned %d events", path, len(got))
			}
			if !strings.HasPrefix(closed, "auth-required") {
				t.Fatalf("%s: want CLOSED auth-required, got %q", path, closed)
			}
		}
		// Authenticated as the owner, /private answers the search.
		r := h.connect(t, "/private")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		deadline := time.Now().Add(3 * time.Second)
		var err error
		for time.Now().Before(deadline) {
			if err = r.Auth(ctx, func(ev *nostr.Event) error { return ev.Sign(h.ownerSK) }); err == nil {
				break
			}
			time.Sleep(50 * time.Millisecond) // challenge not received yet
		}
		if err != nil {
			t.Fatalf("auth: %v", err)
		}
		got, closed := req(t, r, nostr.Filter{Kinds: []int{1}, Search: "launch SECRET"})
		if closed != "" || len(got) != 1 || got[0].ID != secret.ID {
			t.Fatalf("authed /private search: got %v closed=%q", got, closed)
		}
	})

	t.Run("NIP-11 advertises 50 on every route", func(t *testing.T) {
		httpBase := strings.Replace(h.base, "ws://", "http://", 1)
		for _, path := range []string{"/", "/private", "/chat", "/inbox", "/feed"} {
			rq, _ := http.NewRequest("GET", httpBase+path, nil)
			rq.Header.Set("Accept", "application/nostr+json")
			resp, err := http.DefaultClient.Do(rq)
			if err != nil {
				t.Fatal(err)
			}
			var info struct {
				SupportedNIPs []int `json:"supported_nips"`
			}
			err = json.NewDecoder(resp.Body).Decode(&info)
			resp.Body.Close()
			if err != nil {
				t.Fatalf("%s: %v", path, err)
			}
			if !slices.Contains(info.SupportedNIPs, 50) {
				t.Fatalf("%s: supported_nips %v lacks 50", path, info.SupportedNIPs)
			}
		}
	})

	t.Run("live events do not leak into a search subscription", func(t *testing.T) {
		// One case per field detachSearchListener can poison, each filter
		// carrying only that field so it is the branch taken. On /feed,
		// which allows filters without kinds/authors and needs no auth.
		now := time.Now().Unix()
		live := &nostr.Event{Kind: 1, Content: "no stripes here", CreatedAt: nostr.Timestamp(now), Tags: nostr.Tags{{"t", "poisontest"}}}
		if err := live.Sign(h.ownerSK); err != nil {
			t.Fatal(err)
		}
		since := nostr.Timestamp(now - 3600)
		until := nostr.Timestamp(now + 3600)
		cases := []struct {
			name string
			f    nostr.Filter
		}{
			{"kinds", nostr.Filter{Kinds: []int{1}}},
			{"authors", nostr.Filter{Authors: []string{h.owner}}},
			{"ids", nostr.Filter{IDs: []string{live.ID}}},
			{"tags", nostr.Filter{Tags: nostr.TagMap{"t": {"poisontest"}}}},
			{"since", nostr.Filter{Since: &since}},
			{"until", nostr.Filter{Until: &until}},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				assertNoLiveLeak(t, h.connect(t, "/feed"), c.f, live)
			})
		}
	})
}

// assertNoLiveLeak subscribes f plain and f+search on one connection,
// broadcasts live on the feed relay, and requires the plain subscription
// (positive control) to get it and the search subscription not to.
func assertNoLiveLeak(t *testing.T, r *nostr.Relay, f nostr.Filter, live *nostr.Event) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sf := f.Clone()
	sf.Search = "zebra"
	searchSub, err := r.Subscribe(ctx, nostr.Filters{sf})
	if err != nil {
		t.Fatal(err)
	}
	plainSub, err := r.Subscribe(ctx, nostr.Filters{f})
	if err != nil {
		t.Fatal(err)
	}
	// Wait for both EOSEs, consuming stored events (the client blocks
	// dispatch until they are read). The search sub must see none.
	for _, s := range []*nostr.Subscription{searchSub, plainSub} {
	wait:
		for {
			select {
			case ev := <-s.Events:
				if s == searchSub {
					t.Fatalf("search sub got stored event %q", ev.Content)
				}
			case <-s.EndOfStoredEvents:
				break wait
			case reason := <-s.ClosedReason:
				t.Fatalf("subscription %v closed: %s", s.Filters, reason)
			case <-ctx.Done():
				t.Fatalf("no EOSE for %v", s.Filters)
			}
		}
	}
	feedRelay.BroadcastEvent(live)

	select {
	case ev := <-plainSub.Events:
		if ev == nil || ev.ID != live.ID {
			t.Fatalf("control got unexpected %v", ev)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("positive control: plain subscription never got the live event")
	}
	select {
	case ev := <-searchSub.Events:
		t.Fatalf("search subscription received a live event: %q", ev.Content)
	case <-time.After(300 * time.Millisecond):
	}
}

// waitSearchIdle waits for every scan slot to be returned.
func waitSearchIdle(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		searchSlots.mu.Lock()
		active, conns := searchSlots.active, len(searchSlots.byConn)
		searchSlots.mu.Unlock()
		if active == 0 && conns == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("scan slots leaked: active=%d connections=%d", active, conns)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSearchConcurrencyCaps(t *testing.T) {
	h := startHaven(t)
	saveAll(t, outboxDB, signedAt(t, h.ownerSK, 1, "qzqzqz found", time.Now().Unix()-10))
	noMatch := nostr.Filter{Kinds: []int{1}, Search: "nothingmatches"}
	hit := nostr.Filter{Kinds: []int{1}, Search: "qzqzqz"}

	t.Run("two search filters in one REQ are fine", func(t *testing.T) {
		got, closed := reqMany(t, h.connect(t, ""), nostr.Filters{hit, {Kinds: []int{0}, Search: "qzqzqz"}})
		if closed != "" || len(got) != 1 {
			t.Fatalf("got %d events closed=%q", len(got), closed)
		}
		waitSearchIdle(t)
	})

	t.Run("REQ with more search filters than the per-connection cap is refused", func(t *testing.T) {
		hold := make(chan struct{})
		searchTestHold = hold
		defer func() { searchTestHold = nil; close(hold) }()

		var fs nostr.Filters
		for i := 0; i < 50; i++ {
			fs = append(fs, noMatch)
		}
		got, closed := reqMany(t, h.connect(t, ""), fs)
		if len(got) != 0 || closed != errSearchConnBusy.Error() {
			t.Fatalf("want CLOSED %q, got %d events closed=%q", errSearchConnBusy, len(got), closed)
		}
		// The scans started before the refusal are cancelled with the REQ
		// and give their slots back, although the hold is still shut.
		waitSearchIdle(t)
	})

	t.Run("relay-wide cap refuses, then frees up", func(t *testing.T) {
		prev := searchSlots
		searchSlots = newSearchLimiter(2, searchMaxPerConn)
		hold := make(chan struct{})
		searchTestHold = hold
		defer func() { searchTestHold = nil; searchSlots = prev }()

		// Two connections each park one scan: the relay is full.
		parked := make(chan string, 2)
		for i := 0; i < 2; i++ {
			r := h.connect(t, "")
			go func() {
				got, closed := reqMany(t, r, nostr.Filters{hit})
				parked <- fmt.Sprintf("%d:%s", len(got), closed)
			}()
		}
		deadline := time.Now().Add(3 * time.Second)
		for {
			searchSlots.mu.Lock()
			n := searchSlots.active
			searchSlots.mu.Unlock()
			if n == 2 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("parked scans never took their slots (active=%d)", n)
			}
			time.Sleep(10 * time.Millisecond)
		}

		// A third client — even with its own fresh connection — is refused.
		third := h.connect(t, "")
		got, closed := reqMany(t, third, nostr.Filters{hit})
		if len(got) != 0 || closed != errSearchRelayBusy.Error() {
			t.Fatalf("want CLOSED %q, got %d events closed=%q", errSearchRelayBusy, len(got), closed)
		}
		// Plain (non-search) filters are not limited.
		if got, closed := reqMany(t, third, nostr.Filters{{Kinds: []int{1}}}); closed != "" || len(got) != 1 {
			t.Fatalf("plain REQ while search is full: %d events closed=%q", len(got), closed)
		}

		// Release the parked scans; both finish with their result.
		searchTestHold = nil
		close(hold)
		for i := 0; i < 2; i++ {
			if res := <-parked; res != "1:" {
				t.Fatalf("parked search ended %q, want 1 event and EOSE", res)
			}
		}
		waitSearchIdle(t)
		got, closed = reqMany(t, third, nostr.Filters{hit})
		if closed != "" || len(got) != 1 {
			t.Fatalf("after release: %d events closed=%q", len(got), closed)
		}
		waitSearchIdle(t)
	})
}

// reqMany is req with several filters in one REQ.
func reqMany(t *testing.T, r *nostr.Relay, fs nostr.Filters) ([]*nostr.Event, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sub, err := r.Subscribe(ctx, fs)
	if err != nil {
		t.Error(err)
		return nil, "subscribe failed"
	}
	defer sub.Unsub()
	var out []*nostr.Event
	for {
		select {
		case ev := <-sub.Events:
			out = append(out, ev)
		case <-sub.EndOfStoredEvents:
			for {
				select {
				case ev := <-sub.Events:
					out = append(out, ev)
				default:
					return out, ""
				}
			}
		case reason := <-sub.ClosedReason:
			return out, reason
		case <-ctx.Done():
			return out, "timeout"
		}
	}
}

// TestScanSearchPaging walks a store bigger than one page, with a run of
// same-second events straddling a page boundary, on both backends.
func TestScanSearchPaging(t *testing.T) {
	backends := map[string]func(path string) DBBackend{"badger": newBadgerBackend}
	if lmdbFactory != nil {
		backends["lmdb"] = lmdbFactory
	}
	for name, mk := range backends {
		t.Run(name, func(t *testing.T) {
			db := mk(t.TempDir() + "/db")
			if err := db.Init(); err != nil {
				t.Fatal(err)
			}
			defer db.Close()

			sk := nostr.GeneratePrivateKey()
			base := time.Now().Unix()
			total := 0
			want := map[string]bool{}
			add := func(content string, at int64) {
				ev := signedAt(t, sk, 1, content, at)
				saveAll(t, db, ev)
				total++
				if strings.Contains(content, "needle") {
					want[ev.ID] = true
				}
			}
			for i := 0; i < 700; i++ {
				add(fmt.Sprintf("hay %d", i), base-int64(i))
			}
			// 1200 events on one second: more than a page, so the walk
			// has to step past it; one needle sits among them.
			for i := 0; i < 1200; i++ {
				c := fmt.Sprintf("hay burst %d", i)
				if i == 900 {
					c = "burst needle"
				}
				add(c, base-5000)
			}
			// 600 events straddling the next page boundary at 2 per second.
			for i := 0; i < 600; i++ {
				add(fmt.Sprintf("hay tail %d", i), base-6000-int64(i/2))
			}
			add("the oldest needle", base-100000)

			var got []*nostr.Event
			scanned, found, err := scanSearch(context.Background(), db, nostr.Filter{Kinds: []int{1}, Search: "needle"}, 1000, func(ev *nostr.Event) bool {
				got = append(got, ev)
				return true
			})
			if err != nil {
				t.Fatal(err)
			}
			seen := map[string]bool{}
			for _, ev := range got {
				if seen[ev.ID] {
					t.Fatalf("duplicate result %q", ev.Content)
				}
				seen[ev.ID] = true
				if !want[ev.ID] {
					t.Fatalf("non-matching result %q", ev.Content)
				}
			}
			// The burst puts more same-second events than one page carries
			// on one second, so the walk steps past part of it and the burst
			// needle may or may not be read. Everything older must be.
			var oldest bool
			for _, ev := range got {
				if ev.Content == "the oldest needle" {
					oldest = true
				}
			}
			if !oldest {
				t.Fatal("walk did not reach the oldest event")
			}
			if scanned > total {
				t.Fatalf("scanned %d events, store holds %d: something was read twice", scanned, total)
			}
			t.Logf("%s: scanned %d of %d, found %d of %d", name, scanned, total, found, len(want))
		})
	}
}

// TestSearchLatency measures search on a synthetic ~100k-event store.
// Opt-in: HAVEN_SEARCH_BENCH=1 go test -run TestSearchLatency -v
func TestSearchLatency(t *testing.T) {
	if os.Getenv("HAVEN_SEARCH_BENCH") == "" {
		t.Skip("set HAVEN_SEARCH_BENCH=1")
	}
	const n = 100_000
	backends := map[string]func(path string) DBBackend{"badger": newBadgerBackend}
	if lmdbFactory != nil {
		backends["lmdb"] = lmdbFactory
	}
	words := strings.Fields("the a relay nostr bitcoin sovereign note coffee morning photo lightning zap follow garden music code build ship")
	for name, mk := range backends {
		t.Run(name, func(t *testing.T) {
			db := mk(t.TempDir() + "/db")
			if err := db.Init(); err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			base := time.Now().Unix()
			start := time.Now()
			pub := strings.Repeat("ab", 32)
			for i := 0; i < n; i++ {
				kind := 1
				var content string
				switch {
				case i%50 == 0:
					kind = 0
					content = fmt.Sprintf(`{"name":"user%d","about":"%s %s","picture":"https://img.example/%d.png"}`, i, words[i%len(words)], words[(i/7)%len(words)], i)
				default:
					var b strings.Builder
					for w := 0; w < 25; w++ {
						b.WriteString(words[(i*31+w*7)%len(words)])
						b.WriteByte(' ')
					}
					if i == n-1 {
						b.WriteString("rareneedle")
					}
					content = b.String()
				}
				ev := &nostr.Event{
					ID:        fmt.Sprintf("%x", sha256.Sum256([]byte(fmt.Sprint(i)))),
					PubKey:    pub,
					Kind:      kind,
					Content:   content,
					CreatedAt: nostr.Timestamp(base - int64(i)*30),
					Tags:      nostr.Tags{},
				}
				if err := db.SaveEvent(context.Background(), ev); err != nil {
					t.Fatal(err)
				}
			}
			t.Logf("%s: seeded %d events in %s", name, n, time.Since(start).Round(time.Millisecond))

			run := func(label string, f nostr.Filter, limit int) {
				var best time.Duration
				var scanned, found int
				for rep := 0; rep < 3; rep++ {
					t0 := time.Now()
					s, fo, err := scanSearch(context.Background(), db, f, limit, func(*nostr.Event) bool { return true })
					d := time.Since(t0)
					if err != nil {
						t.Fatalf("%s: %v", label, err)
					}
					if rep == 0 || d < best {
						best = d
					}
					scanned, found = s, fo
				}
				t.Logf("%s | %-45s | scanned %6d found %4d | best of 3: %s", name, label, scanned, found, best.Round(time.Millisecond))
			}
			run("common terms, kinds [1], limit 100", nostr.Filter{Kinds: []int{1}, Search: "bitcoin coffee"}, 100)
			run("no match, kinds [1] (full scan)", nostr.Filter{Kinds: []int{1}, Search: "zzznomatch"}, 100)
			run("oldest-only match, kinds [1] (full scan)", nostr.Filter{Kinds: []int{1}, Search: "rareneedle"}, 100)
			run("kind 0 profiles, kinds [0]", nostr.Filter{Kinds: []int{0}, Search: "user4"}, 100)
			run("no match, kinds [0,1] (full scan)", nostr.Filter{Kinds: []int{0, 1}, Search: "zzznomatch"}, 100)
		})
	}
}
