package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
	"github.com/spf13/afero"

	"github.com/barrydeen/haven/internal/followers"
	"github.com/barrydeen/haven/pkg/wot"
)

// Two accounts that both follow y; A alone has blocked y. Also on A's list:
// own account B, which cannot be blocked.
func blocksFixture(t *testing.T) (a, b, y string) {
	t.Helper()
	a, b, y = hexid('a'), hexid('b'), hexid('c')
	setupSyncConfig(a)
	config.WhitelistedPubKeys[b] = struct{}{}
	wot.MarkReady(wot.NewCycle(), stubWot{webs: map[string]map[string]bool{a: {y: true}, b: {y: true}}})
	t.Cleanup(func() { accountBlocksOverride.Store(nil) })
	UpdateAccountBlocks(blocksByAccount{a: {y: {}, b: {}}})
	return
}

// served runs events through a read hook and returns the ids that come out.
func served(t *testing.T, wrap func(func(context.Context, nostr.Filter) (chan *nostr.Event, error)) func(context.Context, nostr.Filter) (chan *nostr.Event, error), filter nostr.Filter, events ...*nostr.Event) string {
	t.Helper()
	ch, err := wrap(func(context.Context, nostr.Filter) (chan *nostr.Event, error) {
		out := make(chan *nostr.Event, len(events))
		for _, ev := range events {
			out <- ev
		}
		close(out)
		return out, nil
	})(context.Background(), filter)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for ev := range ch {
		ids = append(ids, ev.ID[:1])
	}
	return strings.Join(ids, "")
}

func pFilter(accounts ...string) nostr.Filter {
	return nostr.Filter{Tags: nostr.TagMap{"p": accounts}}
}

func TestABlockBelongsToTheAccountThatMadeIt(t *testing.T) {
	a, b, y := blocksFixture(t)
	ctx := context.Background()

	if !blockedBy(a, y) || blockedBy(b, y) {
		t.Fatal("y is blocked by A and not by B")
	}
	if blockedBy(a, b) {
		t.Fatal("own account B is on A's list and must not count as blocked")
	}

	// y → A: refused as blocked. y → B: kept. y → A and B: kept for B alone.
	if c := classifyInboxEvent(ctx, gateNote('1', y, nostr.Tag{"p", a})); c.accept || c.reason != rejectBlacklist || c.reason.permanent() {
		t.Fatalf("y → A: %+v, want a block rejection that can change", c)
	}
	if c := classifyInboxEvent(ctx, gateNote('2', y, nostr.Tag{"p", b})); !c.accept || c.recipient != b {
		t.Fatalf("y → B: %+v, want kept for B (only A blocked y)", c)
	}
	if c := classifyInboxEvent(ctx, gateNote('3', y, nostr.Tag{"p", a}, nostr.Tag{"p", b})); !c.accept || strings.Join(c.recipients, ",") != b {
		t.Fatalf("y → A, B: recipients %v, want B alone", c.recipients)
	}
	// Own account B → A still gets through.
	if c := classifyInboxEvent(ctx, gateNote('4', b, nostr.Tag{"p", a})); !c.accept || c.recipient != a {
		t.Fatalf("own B → A: %+v", c)
	}

	// The relay's write gate agrees, for the author and for an AUTH'd sender.
	if reject, _ := MustBeInWotToPost(authedAs(y), gateNote('5', y, nostr.Tag{"p", a})); !reject {
		t.Error("write gate let y through to A, who blocked y")
	}
	if reject, _ := MustBeInWotToPost(ctx, gateNote('6', y, nostr.Tag{"p", b})); reject {
		t.Error("write gate refused y → B")
	}
	wrap := gateNote('7', hexid('9'), nostr.Tag{"p", a})
	wrap.Kind = nostr.KindGiftWrap
	if reject, _ := MustBeInWotToPost(authedAs(y), wrap); !reject {
		t.Error("y's gift wrap reached A, who blocked y")
	}

	// A remembered refusal is rechecked against the account's blocks too.
	if mayNowReach(ctx, y, []string{a}) || !mayNowReach(ctx, y, []string{b}) || !mayNowReach(ctx, y, nil) {
		t.Error("recheck: y must stay refused for A, and clear for B or when no account was tagged")
	}

	// The old vault-wide list still applies to every account.
	t.Cleanup(func() { blacklistOverride.Store(nil) })
	UpdateBlacklist(map[string]struct{}{y: {}})
	if c := classifyInboxEvent(ctx, gateNote('8', y, nostr.Tag{"p", b})); c.accept || c.reason != rejectBlacklist {
		t.Fatalf("vault-wide block, y → B: %+v", c)
	}
}

// A read hides someone only when every account it is for has blocked them.
func TestBlockedPeopleAreHiddenPerRead(t *testing.T) {
	a, b, y := blocksFixture(t)
	z := hexid('d')
	theirs, others, own := gateNote('y', y), gateNote('z', z), gateNote('b', b)
	read := func(f nostr.Filter) string { return served(t, hideBlacklistedQuery, f, theirs, others, own) }

	if got := read(pFilter(a)); got != "zb" {
		t.Errorf("A's read served %q, want y hidden and own account B served", got)
	}
	if got := read(pFilter(b)); got != "yzb" {
		t.Errorf("B's read served %q: A's block must not hide y from B", got)
	}
	// Naming the account as an author scopes the read to it too.
	if got := read(nostr.Filter{Authors: []string{a, y, z}}); got != "zb" {
		t.Errorf("a read of A's, y's and z's notes served %q, want y hidden", got)
	}
	for name, f := range map[string]nostr.Filter{"both accounts": pFilter(a, b), "no account": {}} {
		if got := read(f); got != "yzb" {
			t.Errorf("%s: served %q; only one account blocked y, so the app's own filter decides", name, got)
		}
	}
	if got := hiddenAuthors(readScope(pFilter(a)), []string{y, z}); len(got) != 1 || got[0] != y {
		t.Errorf("hiddenAuthors for A, asked for y and z: %v", got)
	}
	// Both block y: hidden from every read.
	UpdateAccountBlocks(blocksByAccount{a: {y: {}}, b: {y: {}}})
	for name, f := range map[string]nostr.Filter{"A": pFilter(a), "both": pFilter(a, b), "none": {}} {
		if got := read(f); got != "zb" {
			t.Errorf("both blocked y, read for %s served %q", name, got)
		}
	}
}

func TestFollowersHideWhatThatAccountBlocked(t *testing.T) {
	a, b, y := blocksFixture(t)
	l, err := followers.Open(afero.NewMemMapFs(), "followers.json", []string{a, b})
	if err != nil {
		t.Fatal(err)
	}
	followerLedger.Store(l)
	t.Cleanup(func() { followerLedger.Store(nil) })
	observeFollowList(&nostr.Event{ID: hexid('1'), PubKey: y, Kind: nostr.KindFollowList,
		CreatedAt: nostr.Now() + 1, Tags: nostr.Tags{{"p", a}, {"p", b}}})
	count := func(owner string) int {
		snap, ok := followersSnapshot(t.Context(), owner)
		if !ok {
			t.Fatal("no snapshot")
		}
		return len(snap.Followers)
	}
	if count(a) != 0 || count(b) != 1 {
		t.Errorf("y on A's list: %d, on B's: %d; want hidden from A only", count(a), count(b))
	}
}

// An inbox read for one account leaves out what is in the store only because
// another account lets its author in.
func TestInboxReadLeavesOutAnotherAccountsMail(t *testing.T) {
	a, b, x, stranger := gateFixture(t) // A follows x, B follows nobody
	forBoth := gateNote('1', x, nostr.Tag{"p", a}, nostr.Tag{"p", b})
	forB := gateNote('2', x, nostr.Tag{"p", b}) // nobody lets it in now: served as before
	stale := gateNote('3', stranger, nostr.Tag{"p", a}, nostr.Tag{"p", b})
	wrap := gateNote('4', stranger, nostr.Tag{"p", a}, nostr.Tag{"p", b})
	wrap.Kind = nostr.KindGiftWrap
	fromOwn := gateNote('5', a, nostr.Tag{"p", a}, nostr.Tag{"p", b})
	read := func(f nostr.Filter) string {
		return served(t, scopeInboxQuery, f, forBoth, forB, stale, wrap, fromOwn)
	}

	if got := read(pFilter(b)); got != "2345" {
		t.Errorf("B's inbox read served %q, want x's note to A and B left out", got)
	}
	if got := read(pFilter(a)); got != "12345" {
		t.Errorf("A's inbox read served %q, want everything", got)
	}
	for name, f := range map[string]nostr.Filter{"both accounts": pFilter(a, b), "no account": {}} {
		if got := read(f); got != "12345" {
			t.Errorf("%s: served %q, want everything", name, got)
		}
	}
	// One account on the vault: nothing is another account's.
	delete(config.WhitelistedPubKeys, a)
	if got := read(pFilter(b)); got != "12345" {
		t.Errorf("single account: served %q, want everything", got)
	}
}

func TestAccountBlocksAreParsedPerAccount(t *testing.T) {
	npub := func(hex string) string {
		n, err := nip19.EncodePublicKey(hex)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	sk := func() string {
		pk, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
		return pk
	}
	a, b, y, z := sk(), sk(), sk(), sk()
	blocks, err := parseAccountBlocks([]byte(`{"v":1,"accounts":{
		"` + npub(a) + `":["` + npub(y) + `","not-an-npub","` + npub(z) + `"],
		"` + npub(b) + `":[],
		"bad":["` + npub(y) + `"]}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(blocks) != 2 || len(blocks[a]) != 2 || len(blocks[b]) != 0 {
		t.Fatalf("parsed %v", blocks)
	}
	if _, ok := blocks[a][y]; !ok {
		t.Error("A's block of y is missing")
	}
	for name, body := range map[string]string{"another version": `{"v":2,"accounts":{}}`, "a list": `["x"]`, "broken": `{"v":1,`} {
		if _, err := parseAccountBlocks([]byte(body)); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	if got := loadAccountBlocks(t.TempDir() + "/absent.json"); got != nil {
		t.Errorf("no file gave %v, want none", got)
	}
}

// A zap receipt is signed by the wallet's server: a stored one from someone
// the account blocked is hidden by its zapper, like a new one is refused.
func TestStoredZapFromABlockedZapperIsHidden(t *testing.T) {
	a, _, _ := blocksFixture(t)
	zapperSK, serviceSK := nostr.GeneratePrivateKey(), nostr.GeneratePrivateKey()
	zapper, _ := nostr.GetPublicKey(zapperSK)
	receipt := zapPair(t, zapperSK, serviceSK, a, false)
	other := gateNote('z', hexid('d'))
	read := func() int {
		return len(served(t, hideBlacklistedQuery, pFilter(a), receipt, other))
	}
	if read() != 2 {
		t.Fatal("fixture: before the block the receipt is served")
	}
	UpdateAccountBlocks(blocksByAccount{a: {zapper: {}}})
	if read() != 1 {
		t.Error("A blocked the zapper, and the stored zap receipt was still served")
	}
}

// The list of hidden people names each once, however many lists they are on,
// and the "anything to hide?" check every read makes agrees with it.
func TestHiddenAuthorsNamesEachOnce(t *testing.T) {
	a, _, y := blocksFixture(t) // y is on A's list
	t.Cleanup(func() { blacklistOverride.Store(nil) })
	UpdateBlacklist(map[string]struct{}{y: {}, hexid('e'): {}})
	scope := readScope(pFilter(a))
	if got := hiddenAuthors(scope, nil); len(got) != 2 {
		t.Errorf("hidden %v, want y and e once each", got)
	}
	if got := hiddenAuthors(scope, []string{y, y, hexid('f')}); len(got) != 1 || got[0] != y {
		t.Errorf("hidden among the filter's authors: %v, want y once", got)
	}
	if !hidesAnyone(scope, nil) || hidesAnyone(scope, []string{hexid('f')}) {
		t.Error("hidesAnyone: want true for the scope, false when the filter names only f")
	}
	UpdateBlacklist(map[string]struct{}{})
	UpdateAccountBlocks(blocksByAccount{})
	if hidesAnyone(scope, nil) || len(hiddenAuthors(scope, nil)) != 0 {
		t.Error("nobody blocked, and the read still hides someone")
	}
}

// No host names the per-account files yet: with none named, none is read,
// so a stray file in the working directory cannot become settings.
func TestAccountFilesAreOnlyReadWhenNamed(t *testing.T) {
	t.Chdir(t.TempDir())
	npub, _ := reachTestAccount(t)
	for name, body := range map[string]string{
		"account_reach.json":     `{"v":1,"accounts":{"` + npub + `":{"depth":1}}}`,
		"blocks_by_account.json": `{"v":1,"accounts":{"` + npub + `":["` + npub + `"]}}`,
	} {
		if err := os.WriteFile(name, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// Setenv registers the restore; Unsetenv is what makes the default apply.
	for _, key := range []string{"ACCOUNT_REACH_FILE", "BLOCKS_BY_ACCOUNT_FILE"} {
		t.Setenv(key, "")
		os.Unsetenv(key)
	}
	saved := config
	t.Cleanup(func() { config = saved; resetLiveAccounts() })
	cfg := loadConfig()
	if len(cfg.AccountReach) != 0 || cfg.AccountBlocks != nil {
		t.Errorf("unnamed files were read: reach %v, blocks %v", cfg.AccountReach, cfg.AccountBlocks)
	}
	t.Setenv("ACCOUNT_REACH_FILE", "account_reach.json")
	t.Setenv("BLOCKS_BY_ACCOUNT_FILE", "blocks_by_account.json")
	if cfg = loadConfig(); len(cfg.AccountReach) != 1 || len(cfg.AccountBlocks) != 1 {
		t.Errorf("named files were not read: reach %v, blocks %v", cfg.AccountReach, cfg.AccountBlocks)
	}
}
