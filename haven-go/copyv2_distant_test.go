//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/trustrank"
)

// distantSetup: a Haven (aDir) whose owner has a follow (hop 1), a circle
// member (hop 2) and two distant connections (hop 3 at 70, hop 4 at 60),
// and a feed store holding notes by each of them.
type distantSetup struct {
	owner, follow, circle, far3, far4 testKey
	aDir, bDir, url                   string
	notes                             map[string]nostr.Event
}

func newDistantSetup(t *testing.T) distantSetup {
	t.Helper()
	owner, aDir, bDir, _, url := trustPair(t, 0)
	d := distantSetup{owner: owner, follow: newTestKey(t), circle: newTestKey(t), far3: newTestKey(t), far4: newTestKey(t),
		aDir: aDir, bDir: bDir, url: url, notes: map[string]nostr.Event{}}
	config.FeedSyncWindowDays = 7
	f := trustrank.ResultFile{Account: owner.pk, BuiltAt: 100, Version: 2, MaxHop: 4, ViewBar: trustrank.DefaultViewBar,
		Params: trustrank.DefaultParams(),
		People: [][3]any{{d.follow.pk, 12.0, 1}, {d.circle.pk, 99.0, 2}, {d.far3.pk, 70.0, 3}, {d.far4.pk, 60.0, 4}}}
	writeDistantResult(t, aDir, f)
	old := nostr.Timestamp(time.Now().Add(-10 * 24 * time.Hour).Unix())
	for name, ev := range map[string]nostr.Event{
		"follow":  d.follow.sign(t, nostr.Event{Kind: 1, Content: "follow"}),
		"circle":  d.circle.sign(t, nostr.Event{Kind: 1, Content: "circle"}),
		"far3":    d.far3.sign(t, nostr.Event{Kind: 1, Content: "far3"}),
		"far4":    d.far4.sign(t, nostr.Event{Kind: 30023, Content: "far4", Tags: nostr.Tags{{"d", "a"}}}),
		"far3old": d.far3.sign(t, nostr.Event{Kind: 1, Content: "too old", CreatedAt: old}),
		"far3dm":  d.far3.sign(t, nostr.Event{Kind: 4, Content: "not a feed kind"}),
	} {
		saveEv(t, feedDB, ev)
		d.notes[name] = ev
	}
	return d
}

func writeDistantResult(t *testing.T, dir string, f trustrank.ResultFile) {
	t.Helper()
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(trustrank.ResultPath(dir, f.Account), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func distantGet(t *testing.T, url, query, bearer string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url+"/copy/v2/sync/distant"+query, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func distantContents(t *testing.T, body []byte) []string {
	t.Helper()
	var out []string
	for _, line := range bytes.Split(bytes.TrimSpace(body), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var ev nostr.Event
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("bad line %q", line)
		}
		out = append(out, ev.Content)
	}
	return out
}

// The Haven hands out only feed notes by the account's distant connections
// (hop 3+) inside the feed window: not the follow's, the circle's, an old
// note or another kind.
func TestCopyDistantHandsOutOnlyDistantFeedNotes(t *testing.T) {
	d := newDistantSetup(t)
	code, body := distantGet(t, d.url, "?account="+d.owner.pk, copyPeerToken("npub1peer"))
	if code != http.StatusOK {
		t.Fatalf("status %d", code)
	}
	got := strings.Join(distantContents(t, body), ",")
	if got != "far3,far4" && got != "far4,far3" {
		t.Fatalf("handed out %q", got)
	}
}

// Who gets it: a paired device's token only, for an account this Haven
// ranks only, and nothing before the Haven has a result.
func TestCopyDistantIsForPairedDevicesOnly(t *testing.T) {
	d := newDistantSetup(t)
	token := copyPeerToken("npub1peer")
	q := "?account=" + d.owner.pk
	if code, _ := distantGet(t, d.url, q, ""); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := distantGet(t, d.url, q, copyRandomHex(32)); code != http.StatusUnauthorized {
		t.Fatalf("a made-up token: %d", code)
	}
	other := newTestKey(t)
	writeDistantResult(t, d.aDir, trustrank.ResultFile{Account: other.pk, BuiltAt: 100, Version: 2, MaxHop: 4,
		People: [][3]any{{d.far3.pk, 70.0, 3}}})
	if code, _ := distantGet(t, d.url, "?account="+other.pk, token); code != http.StatusNotFound {
		t.Fatalf("an account this Haven does not rank: %d", code)
	}
	for _, bad := range []string{"", "?account=..%2F..%2Fconfig"} {
		if code, _ := distantGet(t, d.url, bad, token); code != http.StatusNotFound {
			t.Fatalf("account %q: %d", bad, code)
		}
	}
	if err := os.Remove(trustrank.ResultPath(d.aDir, d.owner.pk)); err != nil {
		t.Fatal(err)
	}
	if code, _ := distantGet(t, d.url, q, token); code != http.StatusNotFound {
		t.Fatalf("no result yet: %d", code)
	}
}

// The device keeps only checked notes by authors it allows, in its own
// feed store: a forged note, an author not on its list and another kind
// are refused, and a body over the line cap is not ok.
func TestCopyDistantDeviceKeepsOnlyCheckedNotes(t *testing.T) {
	d := newDistantSetup(t)
	_, body := distantGet(t, d.url, "?account="+d.owner.pk, copyPeerToken("npub1peer"))

	forged := d.notes["far3"]
	forged.Content = "changed after signing"
	stranger := newTestKey(t).sign(t, nostr.Event{Kind: 1, Content: "stranger"})
	extra, _ := json.Marshal(forged)
	body = append(body, append(extra, '\n')...)
	extra, _ = json.Marshal(stranger)
	body = append(body, append(extra, '\n')...)
	extra, _ = json.Marshal(d.notes["far3dm"])
	body = append(body, append(extra, '\n')...)

	// The phone's own, empty feed store.
	phoneFeed := fallbackBackend(filepath.Join(t.TempDir(), "feed"))
	if err := phoneFeed.Init(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(phoneFeed.Close)
	feedDB = phoneFeed
	allowed := map[string]bool{d.far3.pk: true, d.far4.pk: true}
	got, ok := keepDistantLines(context.Background(), bytes.NewReader(body), allowed)
	if !ok || got != 2 {
		t.Fatalf("kept %d ok=%v, want 2 true", got, ok)
	}
	if n := countIn(t, phoneFeed, nostr.Filter{}); n != 2 {
		t.Fatalf("phone feed holds %d notes", n)
	}
	if n := countIn(t, phoneFeed, nostr.Filter{Authors: []string{stranger.PubKey}}); n != 0 {
		t.Fatal("a stranger's note was kept")
	}

	var many bytes.Buffer
	for range copyDistantMaxEvents + 1 {
		many.WriteString("{}\n")
	}
	if _, ok := keepDistantLines(context.Background(), &many, allowed); ok {
		t.Fatal("a body over the line cap read as whole")
	}
}

// Both sides pick the same people from the same file: the device's check
// list matches the Haven's, mutes left out.
func TestDistantAuthorsCachedByBuiltAt(t *testing.T) {
	d := newDistantSetup(t)
	first := distantAuthors(d.aDir, d.owner.pk)
	if strings.Join(first, ",") != d.far3.pk+","+d.far4.pk {
		t.Fatalf("pick %v", first)
	}
	// A newer pass that drops far4 is read again.
	writeDistantResult(t, d.aDir, trustrank.ResultFile{Account: d.owner.pk, BuiltAt: 200, Version: 2, MaxHop: 4,
		People: [][3]any{{d.far3.pk, 70.0, 3}}})
	if got := distantAuthors(d.aDir, d.owner.pk); len(got) != 1 || got[0] != d.far3.pk {
		t.Fatalf("after a new pass: %v", got)
	}
	// The owner's public mute leaves far3 out (a new pass reads mutes again).
	saveEv(t, outboxDB, d.owner.sign(t, nostr.Event{Kind: 10000, Tags: nostr.Tags{{"p", d.far3.pk}}}))
	writeDistantResult(t, d.aDir, trustrank.ResultFile{Account: d.owner.pk, BuiltAt: 300, Version: 2, MaxHop: 4,
		People: [][3]any{{d.far3.pk, 70.0, 3}, {d.far4.pk, 60.0, 4}}})
	if got := distantAuthors(d.aDir, d.owner.pk); len(got) != 1 || got[0] != d.far4.pk {
		t.Fatalf("muted far3 still picked: %v", got)
	}
}
