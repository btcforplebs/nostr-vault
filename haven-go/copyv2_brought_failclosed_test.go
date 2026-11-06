//go:build !(js && wasm)

package main

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Tron, #1827: when copy-brought.json can't be written, the restore must not
// go on. Otherwise a look-only account's notes land in B's outbox unmarked,
// and the public outbox, negentropy and the feed page serve them as own.
func TestCopyStopsWhenBroughtListCannotBeWritten(t *testing.T) {
	owner, look := newTestKey(t), newTestKey(t)
	t.Cleanup(resetLiveAccounts)

	openCopyVault(t, owner.pk)
	config.WhitelistedPubKeys = map[string]struct{}{owner.pk: {}, look.pk: {}}
	lookNote := look.sign(t, nostr.Event{Kind: 1, Content: "look's note"})
	saveEv(t, outboxDB, owner.sign(t, nostr.Event{Kind: 1, Content: "owner's note"}))
	saveEv(t, outboxDB, lookNote)
	app := `{"v":1,"updated_at":5,"accounts":[{"npub":"` + npubOf(t, owner.pk) + `","name":"Me"}]}`
	if err := os.WriteFile(copyAccountsFile, []byte(app), 0o600); err != nil {
		t.Fatal(err)
	}
	ts, _ := buildAndServeCopy(t)

	openCopyVault(t, owner.pk)
	if err := os.Mkdir(copyBroughtFile+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	copyPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { copyPollEvery = 2 * time.Second })
	var logs bytes.Buffer
	captureLog(t, &logs)
	c := newCopyClient("npub1peer", ts.URL)
	c.free = func(string) (uint64, bool) { return 1 << 40, true }
	if err := c.run(context.Background(), startProof(t, owner, nostr.Now(), "/copy/v2/start")); err == nil {
		t.Fatal("the copy went on with no brought-over list")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{lookNote.ID}}) != 0 {
		t.Fatal("the look-only account's note was restored unmarked")
	}
}

// The backup restore takes the same stop (jsonl.go), and an existing list it
// can't parse is an error, never overwritten (that would drop earlier marks).
func TestRestoreStopsWhenBroughtListIsBroken(t *testing.T) {
	me, them := newTestKey(t), newTestKey(t)
	openCopyVault(t, me.pk)
	t.Cleanup(resetLiveAccounts)
	theirNote := them.sign(t, nostr.Event{Kind: 1, Content: "their note"})
	shared := `{"v":1,"updated_at":1,"accounts":[{"npub":"` + npubOf(t, them.pk) + `"},{"npub":"` + npubOf(t, me.pk) + `"}]}`

	if err := os.WriteFile(copyBroughtFile, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := importFromZip(context.Background(), writeAccountsZip(t, shared, theirNote)); err == nil {
		t.Fatal("the restore went on over a broken brought-over list")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 0 {
		t.Fatal("their note was restored unmarked")
	}
	if raw, _ := os.ReadFile(copyBroughtFile); !strings.HasPrefix(string(raw), "{not json") {
		t.Fatalf("the broken list was overwritten: %s", raw)
	}

	// Unwritable: same stop.
	if err := os.Remove(copyBroughtFile); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(copyBroughtFile+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := importFromZip(context.Background(), writeAccountsZip(t, shared, theirNote)); err == nil {
		t.Fatal("the restore went on with no brought-over list")
	}
	if countIn(t, outboxDB, nostr.Filter{IDs: []string{theirNote.ID}}) != 0 {
		t.Fatal("their note was restored unmarked")
	}
}
