package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// Moving in pulls the user's older list versions from history relays (Lazarus) into the vault's list history
// (Logen 2026-11-04). /lists takes exactly that write: one of this vault's apps (AUTHed as a whitelisted key, as a
// read is) filing a protected list signed by one of this vault's accounts. The version goes to the history store
// only, never the outbox.

func authedAs(pk string) context.Context {
	return context.WithValue(context.Background(), 0, &khatru.WebSocket{AuthedPublicKey: pk})
}

func TestListHistoryWritePolicy(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f := newListHistoryFixture(t, open)
			mine := f.bookmarks(3, 0)
			deviceSk := nostr.GeneratePrivateKey()
			device, _ := nostr.GetPublicKey(deviceSk)
			config.WhitelistedPubKeys[device] = struct{}{}
			other := nostr.GeneratePrivateKey()
			otherPk, _ := nostr.GetPublicKey(other)
			theirs := signedList(t, other, 10003, f.now, nil)
			note := signedList(t, f.sk, 1, f.now, nil)
			ahead := signedList(t, f.sk, 10003, time.Now().Add(time.Hour), nil)
			cases := []struct {
				name   string
				ctx    context.Context
				ev     *nostr.Event
				reject string // "" = accepted; else a substring of the reason
			}{
				{"no auth", context.Background(), mine, "auth-required"},
				{"authed as a stranger", authedAs(otherPk), mine, "restricted"},
				{"not an account of this vault", authedAs(f.pk), theirs, "restricted"},
				{"the browser vault's device key", authedAs(device), mine, ""},
				{"not a list", authedAs(f.pk), note, "blocked"},
				{"dated ahead", authedAs(f.pk), ahead, "invalid"},
				{"over the mesh", meshCtx(), mine, "restricted"},
				{"the owner's own list", authedAs(f.pk), mine, ""},
			}
			for _, c := range cases {
				rejected, why := rejectListHistoryWrite(c.ctx, c.ev)
				if c.reject == "" && rejected {
					t.Errorf("%s: refused (%s)", c.name, why)
				}
				if c.reject != "" && (!rejected || !strings.HasPrefix(why, c.reject)) {
					t.Errorf("%s: want %q, got rejected=%v %q", c.name, c.reject, rejected, why)
				}
			}
		})
	}
}

// An accepted older version lands in history only: the outbox, the current list, is untouched.
func TestListHistoryWriteFilesHistoryOnly(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f := newListHistoryFixture(t, open)
			current := f.bookmarks(10, 60)
			f.publish(current)
			rl := initListsRelay()
			if len(rl.ReplaceEvent) != 1 {
				t.Fatalf("want one replace hook, got %d", len(rl.ReplaceEvent))
			}
			// Newest first, as the app files them.
			old := []*nostr.Event{f.bookmarks(12, 40), f.bookmarks(11, 20), f.bookmarks(2, 10)}
			for _, ev := range old {
				if err := rl.ReplaceEvent[0](authedAs(f.pk), ev); err != nil {
					t.Fatal(err)
				}
			}
			// The same version twice is one version.
			if err := rl.ReplaceEvent[0](authedAs(f.pk), old[0]); err != nil {
				t.Fatal(err)
			}
			got := f.versionIDs(10003, "")
			want := []string{current.ID, old[0].ID, old[1].ID, old[2].ID}
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("history %v, want %v", got, want)
			}
			if out := outboxCopies(t, f.outbox, f.pk, 10003); len(out) != 1 || out[0] != current.ID {
				t.Fatalf("the outbox changed: %v", out)
			}
		})
	}
}

// Filed versions aren't trimmed one at a time (that would let the copy from before a wipe go before the wipe
// arrived); the next version that reaches the outbox trims the whole list at once: the newest listHistoryKeep, plus
// what a wipe pins, here a full list from far past the newest 20.
func TestListHistoryImportThenTrimKeepsTheCopyBeforeAWipe(t *testing.T) {
	for name, open := range historyBackends(t) {
		t.Run(name, func(t *testing.T) {
			f := newListHistoryFixture(t, open)
			rl := initListsRelay()
			full := f.bookmarks(40, 0) // the list before it was wiped
			wiped := f.bookmarks(1, 1) // the wipe
			var after []*nostr.Event   // 30 small edits since
			for i := 0; i < 30; i++ {
				after = append(after, f.bookmarksFrom(100+i, 2, 2+i))
			}
			// Newest first, as the app files them.
			all := append([]*nostr.Event{}, after...)
			for i, j := 0, len(all)-1; i < j; i, j = i+1, j-1 {
				all[i], all[j] = all[j], all[i]
			}
			all = append(all, wiped, full)
			for _, ev := range all {
				if err := rl.ReplaceEvent[0](authedAs(f.pk), ev); err != nil {
					t.Fatal(err)
				}
			}
			if got := f.versionIDs(10003, ""); len(got) != len(all) {
				t.Fatalf("filed %d, history holds %d: an import trimmed", len(all), len(got))
			}
			// The user's next edit reaches the outbox: the list is trimmed once, over everything.
			f.publish(f.bookmarksFrom(100, 3, 40))
			got := f.versionIDs(10003, "")
			has := map[string]bool{}
			for _, id := range got {
				has[id] = true
			}
			if !has[full.ID] || !has[wiped.ID] {
				t.Fatalf("the copy from before the wipe (or the wipe) was let go: %d kept", len(got))
			}
			if len(got) > listHistoryKeep+3 {
				t.Fatalf("kept %d, more than the newest %d and a drain's pins", len(got), listHistoryKeep)
			}
		})
	}
}

// An import can't grow one list without end: at listHistoryImportMax it trims.
func TestListHistoryImportIsBounded(t *testing.T) {
	f := newListHistoryFixture(t, historyBackends(t)[fallbackBackendName])
	rl := initListsRelay()
	for i := 0; i < listHistoryImportMax+5; i++ {
		if err := rl.ReplaceEvent[0](authedAs(f.pk), f.bookmarksFrom(i, 1, -i)); err != nil {
			t.Fatal(err)
		}
	}
	if got := len(f.versionIDs(10003, "")); got >= listHistoryImportMax {
		t.Fatalf("history holds %d versions after an import of %d", got, listHistoryImportMax+5)
	}
}
