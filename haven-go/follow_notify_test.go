package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/barrydeen/haven/internal/followers"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// A follow the ledger watched happen raises exactly one "type=follow" marker;
// republishes, bot-sized lists, refollow bots and old lists stay silent.
func TestFollowNotifyMarker(t *testing.T) {
	owner := hexid('0')
	setupSyncConfig(owner)
	l, err := followers.Open(afero.NewMemMapFs(), "followers.json", []string{owner})
	if err != nil {
		t.Fatal(err)
	}
	followerLedger.Store(l)
	t.Cleanup(func() { followerLedger.Store(nil) })

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	now := nostr.Now()
	list := func(id, author byte, at nostr.Timestamp, extra int) *nostr.Event {
		tags := nostr.Tags{{"p", owner}}
		for i := 0; i < extra; i++ {
			tags = append(tags, nostr.Tag{"p", "x"})
		}
		return &nostr.Event{ID: hexid(id), PubKey: hexid(author), Kind: nostr.KindFollowList, CreatedAt: at, Tags: tags}
	}

	observeFollowList(list('a', '1', now+1, 0))                                           // new follower: notifies
	observeFollowList(list('b', '1', now+2, 0))                                           // republish: silent
	observeFollowList(list('c', '2', now+1, followers.SpamListSize))                      // follow-everyone bot: silent
	observeFollowList(list('d', '3', now+1-nostr.Timestamp(48*time.Hour/time.Second), 0)) // predates ledger: silent
	// Refollow bot: its first follow is news (nothing marks it yet), but after
	// a day of republishing its comeback a week later stays silent.
	week := nostr.Timestamp(7 * 24 * time.Hour / time.Second)
	observeFollowList(list('e', '4', now+1, 0))
	for i := 2; i <= followers.SpamChurn24h; i++ {
		observeFollowList(list('f', '4', now+nostr.Timestamp(i), 0))
	}
	drop := &nostr.Event{ID: hexid('9'), PubKey: hexid('4'), Kind: nostr.KindFollowList, CreatedAt: now + 30}
	observeFollowList(drop)
	observeFollowList(list('8', '4', now+31+week, 0))

	markers := strings.Count(buf.String(), "🔔NOTIFY|")
	want := "🔔NOTIFY|type=follow|kind=3|author=" + hexid('1') + "|id=" + hexid('a') + "|recipient=" + owner + "|preview="
	bot := "|id=" + hexid('e') + "|"
	if markers != 2 || !strings.Contains(buf.String(), want) || !strings.Contains(buf.String(), bot) {
		t.Fatalf("got %d markers, want %q and the bot's first follow only:\n%s", markers, want, buf.String())
	}
}
