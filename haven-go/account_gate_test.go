package main

import (
	"context"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/internal/followers"
	"github.com/barrydeen/haven/pkg/wot"
)

// Two accounts on one device. A follows x, B follows nobody. What A follows
// must not get x through to B.
// The pooled answer (stubWot.Has: anyone in any account's web) must not let
// one account's people through to another.
func gateFixture(t *testing.T) (a, b, x, stranger string) {
	t.Helper()
	a, b, x, stranger = hexid('a'), hexid('b'), hexid('c'), hexid('d')
	setupSyncConfig(a)
	config.WhitelistedPubKeys[b] = struct{}{}
	wot.MarkReady(wot.NewCycle(), stubWot{webs: map[string]map[string]bool{
		a: {x: true},
		b: {},
	}})
	return
}

func gateNote(id byte, author string, tags ...nostr.Tag) *nostr.Event {
	return &nostr.Event{ID: hexid(id), PubKey: author, Kind: nostr.KindTextNote, CreatedAt: nostr.Now(), Tags: tags}
}

func TestInboxJudgesEachTaggedAccountByItsOwnWeb(t *testing.T) {
	a, b, x, stranger := gateFixture(t)
	ctx := context.Background()

	// x tags B alone: B does not follow x, so it is refused, and not for good
	// (B may follow x later).
	c := classifyInboxEvent(ctx, gateNote('1', x, nostr.Tag{"p", b}))
	if c.accept || c.reason != rejectNotInWot || c.reason.permanent() {
		t.Fatalf("x → B: %+v, want a web rejection that can change", c)
	}
	// x tags A alone: kept for A.
	c = classifyInboxEvent(ctx, gateNote('2', x, nostr.Tag{"p", a}))
	if !c.accept || !c.notify || strings.Join(c.recipients, ",") != a {
		t.Fatalf("x → A: %+v, want kept for A", c)
	}
	// x tags both, B first: kept once, for A only, and A is the recipient.
	c = classifyInboxEvent(ctx, gateNote('3', x, nostr.Tag{"p", b}, nostr.Tag{"p", a}))
	if !c.accept || c.recipient != a || strings.Join(c.recipients, ",") != a {
		t.Fatalf("x → B, A: recipient %s recipients %v, want A alone", c.recipient, c.recipients)
	}
	// A stranger to both is refused whoever it tags.
	if c = classifyInboxEvent(ctx, gateNote('4', stranger, nostr.Tag{"p", a}, nostr.Tag{"p", b})); c.accept || c.reason != rejectNotInWot {
		t.Fatalf("stranger → A, B: %+v", c)
	}
	// A gift wrap comes from a throwaway key: kept for every account it tags.
	wrap := gateNote('5', stranger, nostr.Tag{"p", b})
	wrap.Kind = nostr.KindGiftWrap
	if c = classifyInboxEvent(ctx, wrap); !c.accept || !c.chat || c.recipient != b {
		t.Fatalf("gift wrap → B: %+v", c)
	}
	// Tagging neither account: a stranger's is a web rejection, x's is for good.
	if c = classifyInboxEvent(ctx, gateNote('6', stranger, nostr.Tag{"p", hexid('9')})); c.reason != rejectNotInWot {
		t.Fatalf("stranger, no tag: %+v", c)
	}
	if c = classifyInboxEvent(ctx, gateNote('7', x, nostr.Tag{"p", hexid('9')})); c.reason != rejectNoWhitelistedPTag {
		t.Fatalf("x, no tag: %+v", c)
	}
	if !inAnyAccountsWeb(ctx, x) || inAnyAccountsWeb(ctx, stranger) {
		t.Fatal("inAnyAccountsWeb: want x in (A's web) and the stranger out")
	}
	// The recheck of a remembered refusal asks the accounts the event tagged:
	// x → B stays refused however often it is rechecked (A following x must
	// not clear it, or every round downloads it again), x → A clears.
	rejects := &tempRejects{}
	rejects.add(hexid('1'), nostr.Now(), x, b)
	rejects.add(hexid('2'), nostr.Now(), x, a)
	rejects.add(hexid('3'), nostr.Now(), x) // tagged no account: any web
	rejects.reevaluate(func(pk string, accounts []string) bool { return mayNowReach(ctx, pk, accounts) })
	if _, ok := rejects.m.Load(hexid('1')); !ok {
		t.Error("x → B: the stub was cleared because A follows x")
	}
	for _, id := range []string{hexid('2'), hexid('3')} {
		if _, ok := rejects.m.Load(id); ok {
			t.Error("a refusal its account now admits was not cleared")
		}
	}
}

// Anyone may reply to your post, but only to yours: a stranger answering A's
// post reaches A, not B, even when the reply tags both.
func TestReplyToOneAccountsPostReachesThatAccountOnly(t *testing.T) {
	a, b, _, stranger := gateFixture(t)
	ctx := context.Background()
	saved := outboxDB
	t.Cleanup(func() { outboxDB = saved })
	db := newTestBackend(t, "outbox")
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	outboxDB = db
	post := gateNote('e', a)
	if err := db.SaveEvent(ctx, post); err != nil {
		t.Fatal(err)
	}

	reply := func(id byte, tags ...nostr.Tag) *nostr.Event {
		return gateNote(id, stranger, append(nostr.Tags{{"e", post.ID, "", "root"}}, tags...)...)
	}
	c := classifyInboxEvent(ctx, reply('1', nostr.Tag{"p", a}, nostr.Tag{"p", b}))
	if !c.accept || strings.Join(c.recipients, ",") != a {
		t.Fatalf("reply to A's post tagging A and B: recipients %v (accept %v), want A alone", c.recipients, c.accept)
	}
	if c = classifyInboxEvent(ctx, reply('2', nostr.Tag{"p", b})); c.accept {
		t.Fatalf("reply to A's post tagging only B was kept for %v", c.recipients)
	}
	// The relay's own write gate agrees.
	if reject, _ := MustBeInWotToPost(ctx, reply('3', nostr.Tag{"p", a})); reject {
		t.Error("write gate refused a reply to A's post that tags A")
	}
	if reject, _ := MustBeInWotToPost(ctx, reply('4', nostr.Tag{"p", b})); !reject {
		t.Error("write gate let a reply to A's post through to B")
	}
}

func TestRelayGatesAskTheTaggedAccount(t *testing.T) {
	a, b, x, stranger := gateFixture(t)
	anon := context.Background()

	if reject, _ := MustBeInWotToPost(anon, gateNote('1', x, nostr.Tag{"p", a})); reject {
		t.Error("x → A was refused")
	}
	if reject, msg := MustBeInWotToPost(anon, gateNote('2', x, nostr.Tag{"p", b})); !reject || !strings.HasPrefix(msg, "auth-required") {
		t.Errorf("x → B without AUTH: reject %v %q, want auth-required", reject, msg)
	}
	// Signed in as x does not help: B's web does not hold x.
	if reject, _ := MustBeInWotToPost(authedAs(x), gateNote('3', x, nostr.Tag{"p", b})); !reject {
		t.Error("x → B was let through because A follows x")
	}
	// Tagging both is fine: A lets it in, and the inbox keeps it for A only.
	if reject, _ := MustBeInWotToPost(anon, gateNote('4', x, nostr.Tag{"p", b}, nostr.Tag{"p", a})); reject {
		t.Error("x → B, A was refused")
	}
	// A gift wrap is signed by a throwaway key; the signed-in sender is judged
	// by the tagged account's web.
	wrap := func(id byte, to string) *nostr.Event {
		ev := gateNote(id, stranger, nostr.Tag{"p", to})
		ev.Kind = nostr.KindGiftWrap
		return ev
	}
	if reject, _ := MustBeInWotToPost(authedAs(x), wrap('5', a)); reject {
		t.Error("x's gift wrap to A was refused")
	}
	if reject, _ := MustBeInWotToPost(authedAs(x), wrap('6', b)); !reject {
		t.Error("x's gift wrap to B was let through because A follows x")
	}
	// No account tagged: any account's web, as before.
	if reject, _ := MustBeInWotToPost(anon, gateNote('7', x)); reject {
		t.Error("x with no tag was refused by the web gate")
	}
	if reject, _ := MustBeInWotToPost(authedAs(stranger), gateNote('8', stranger)); !reject {
		t.Error("a stranger with no tag was let through")
	}

	// Reading the chat relay names no account: anyone some account lets in.
	if reject, _ := MustBeInWotToQuery(authedAs(x), nostr.Filter{}); reject {
		t.Error("x could not read the chat relay")
	}
	if reject, _ := MustBeInWotToQuery(authedAs(stranger), nostr.Filter{}); !reject {
		t.Error("a stranger could read the chat relay")
	}
}

// A follower of both accounts is "in your web" only on the account whose web
// holds them.
func TestFollowersAreJudgedByTheAccountsOwnWeb(t *testing.T) {
	a, b, x, _ := gateFixture(t)
	l, err := followers.Open(afero.NewMemMapFs(), "followers.json", []string{a, b})
	if err != nil {
		t.Fatal(err)
	}
	followerLedger.Store(l)
	t.Cleanup(func() { followerLedger.Store(nil) })
	observeFollowList(&nostr.Event{ID: hexid('1'), PubKey: x, Kind: nostr.KindFollowList,
		CreatedAt: nostr.Now() + 1, Tags: nostr.Tags{{"p", a}, {"p", b}}})

	tier := func(owner string) followers.Tier {
		snap, ok := followersSnapshot(t.Context(), owner)
		if !ok || len(snap.Followers) != 1 {
			t.Fatalf("snapshot for %s: %+v", owner[:4], snap)
		}
		return snap.Followers[0].Tier
	}
	if got := tier(a); got != followers.TierTrusted {
		t.Errorf("x on A's followers list is %q, want trusted (A follows x)", got)
	}
	if got := tier(b); got != followers.TierOther {
		t.Errorf("x on B's followers list is %q, want other (only A follows x)", got)
	}
}

// You cannot block your own accounts: a block on one of them, from whichever
// account's list it came, never keeps it out (Logen, 2026-11-22). Anyone
// else on the list stays out.
func TestABlockNeverKeepsOutYourOwnAccount(t *testing.T) {
	a, b, x, _ := gateFixture(t)
	ctx := context.Background()
	t.Cleanup(func() { blacklistOverride.Store(nil) })
	UpdateBlacklist(map[string]struct{}{b: {}, x: {}})

	if isBlacklisted(b) || !isBlacklisted(x) {
		t.Fatal("own account b must not count as blocked; x must")
	}
	c := classifyInboxEvent(ctx, gateNote('1', b, nostr.Tag{"p", a}))
	if !c.accept || c.recipient != a {
		t.Fatalf("own account B → A with B on the block list: %+v, want kept", c)
	}
	if reject, _ := MustNotBeBlacklistedToPost(authedAs(b), gateNote('2', b, nostr.Tag{"p", a})); reject {
		t.Error("the relay refused an own account for being on the block list")
	}
	if c = classifyInboxEvent(ctx, gateNote('3', x, nostr.Tag{"p", a})); c.accept || c.reason != rejectBlacklist {
		t.Fatalf("blocked x → A: %+v, want a block rejection", c)
	}
}
