package main

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"

	"github.com/nbd-wtf/go-nostr"

	"github.com/barrydeen/haven/pkg/wot"
)

// One reply that tags two of the owner's accounts is one event for both:
// the NOTIFY line names every tagged account in recipients=, in tag order,
// and keeps recipient= as the first for parsers that predate it (Logen
// 2026-11-05, RESEARCH/NV_LIVE_VAULT_MULTI_MENTION_ORDER_2026_11_05.md).
func TestNotifyNamesEveryTaggedAccount(t *testing.T) {
	a, b, stranger, author := hexid('a'), hexid('b'), hexid('c'), hexid('d')
	setupSyncConfig(a)
	config.WhitelistedPubKeys[b] = struct{}{}
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})

	ev := &nostr.Event{
		ID: hexid('e'), PubKey: author, Kind: nostr.KindTextNote, Content: "hi both",
		CreatedAt: nostr.Now(),
		Tags:      nostr.Tags{{"p", stranger}, {"p", b}, {"p", a}, {"p", b}},
	}
	c := classifyInboxEvent(context.Background(), ev)
	if !c.accept || !c.notify {
		t.Fatalf("classify = %+v, want accepted and notified", c)
	}
	if c.recipient != b || strings.Join(c.recipients, ",") != b+","+a {
		t.Fatalf("recipient=%s recipients=%v, want %s then [%s %s]", c.recipient, c.recipients, b, b, a)
	}

	line := captureNotify(t, func() { emitInboxNotify(ev, c.recipients...) })
	if strings.Count(line, "🔔NOTIFY|") != 1 {
		t.Fatalf("want exactly one marker for one event, got %q", line)
	}
	if !strings.Contains(line, "|recipient="+b+"|recipients="+b+","+a+"|preview=hi both") {
		t.Fatalf("notify line = %q", line)
	}

	// The batch path (catch-up, negentropy) carries them too.
	n := &batchNotifier{}
	line = captureNotify(t, func() { n.maybeNotify(ev, c.recipients...) })
	if !strings.Contains(line, "|recipients="+b+","+a+"|") {
		t.Fatalf("batch notify line = %q", line)
	}
}

// One tagged account: recipients= is that account alone, recipient= unchanged.
func TestNotifySingleAccountUnchanged(t *testing.T) {
	a, author := hexid('a'), hexid('d')
	setupSyncConfig(a)
	wot.MarkReady(wot.NewCycle(), stubWot{allow: true})
	ev := &nostr.Event{ID: hexid('f'), PubKey: author, Kind: nostr.KindTextNote, Content: "hi",
		CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", a}}}
	c := classifyInboxEvent(context.Background(), ev)
	if c.recipient != a || len(c.recipients) != 1 || c.recipients[0] != a {
		t.Fatalf("classify = %+v", c)
	}
	line := captureNotify(t, func() { emitInboxNotify(ev, c.recipients...) })
	if !strings.Contains(line, "|recipient="+a+"|recipients="+a+"|preview=hi") {
		t.Fatalf("notify line = %q", line)
	}
	// No whitelisted tag: still rejected.
	ev.Tags = nostr.Tags{{"p", hexid('c')}}
	if c := classifyInboxEvent(context.Background(), ev); c.accept || c.reason != rejectNoWhitelistedPTag {
		t.Fatalf("untagged classify = %+v", c)
	}
}

func captureNotify(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	fn()
	return buf.String()
}
