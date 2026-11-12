package main

import (
	"bytes"
	"fmt"
	"log"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The Mac app parses every relay log line (RelayLogParser); on Logen's .99
// Mac the relay logged ~80 KB/s and the parser sat at a full core
// (2026-11-12, RESEARCH/NV_MAC_LOG_VOLUME_2026_11_12.md). These lines were
// cut at the source; the ones the app reads for state stay.

func captureLogs(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	prevSlog := slog.Default()
	log.SetOutput(&buf)
	log.SetFlags(0)
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})))
	t.Cleanup(func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
		slog.SetDefault(prevSlog)
	})
	fn()
	return buf.String()
}

// One line per relay per try, with the relay's error text, is Debug now;
// the per-event "blasted event" summary carries the counts.
func TestBlastPerRelayFailureIsNotLoggedAtInfo(t *testing.T) {
	ctx, _ := blastTestSetup(t, "ws://127.0.0.1:1")
	ev := &nostr.Event{ID: strings.Repeat("a", 64), Kind: 1}
	out := captureLogs(t, func() {
		publishWithRetry(ctx, "ws://127.0.0.1:1", ev, 200*time.Millisecond, 0)
	})
	if strings.Contains(out, "relay") {
		t.Fatalf("per-relay blast failure logged at INFO+: %q", out)
	}
}

// The reaction line led with the reaction's content: any length, any text.
// The app's red dot reads only "new reaction in your inbox".
func TestReactionLineCarriesNoContent(t *testing.T) {
	out := captureLogs(t, func() {
		logInboxImport(&nostr.Event{Kind: nostr.KindReaction, Content: "SECRET-" + strings.Repeat("x", 5000)})
	})
	if !strings.Contains(out, "new reaction in your inbox") {
		t.Fatalf("reaction line lost its marker: %q", out)
	}
	if strings.Contains(out, "SECRET") || len(out) > 120 {
		t.Fatalf("reaction line carries the content (%d bytes): %q", len(out), out)
	}
}

type recordingBadgerLogger struct{ lines []string }

func (r *recordingBadgerLogger) Errorf(f string, a ...interface{}) { r.lines = append(r.lines, "E "+fmt.Sprintf(f, a...)) }
func (r *recordingBadgerLogger) Warningf(f string, a ...interface{}) {
	r.lines = append(r.lines, "W "+fmt.Sprintf(f, a...))
}
func (r *recordingBadgerLogger) Infof(f string, a ...interface{})  { r.lines = append(r.lines, "I "+fmt.Sprintf(f, a...)) }
func (r *recordingBadgerLogger) Debugf(f string, a ...interface{}) { r.lines = append(r.lines, "D "+fmt.Sprintf(f, a...)) }

// Badger's INFO (compactions, "Discard stats", "Set nextTxnTs", table
// sizes) was 8-10% of a phone's relay log; nothing reads it.
func TestQuietBadgerLoggerDropsInfoKeepsWarningsAndErrors(t *testing.T) {
	rec := &recordingBadgerLogger{}
	l := quietBadgerLogger{rec}
	l.Infof("Discard stats nextEmptySlot: %d", 1)
	l.Debugf("debug %d", 1)
	l.Warningf("real warning")
	l.Errorf("real error")
	got := strings.Join(rec.lines, ";")
	if got != "W real warning;E real error" {
		t.Fatalf("badger lines = %q", got)
	}
}

// A NIP-46 sign request logged every tag: one line of hundreds of KB for a
// follow list.
func TestNip46SignLineLogsTagCountNotTags(t *testing.T) {
	tags := nostr.Tags{}
	for i := 0; i < 2000; i++ {
		tags = append(tags, nostr.Tag{"p", strings.Repeat("b", 64)})
	}
	line := nip46SignLogLine(&nostr.Event{Kind: 3, PubKey: strings.Repeat("c", 64), Tags: tags})
	if strings.Contains(line, "bbbb") || len(line) > 200 {
		t.Fatalf("sign line carries the tags (%d bytes)", len(line))
	}
	if !strings.Contains(line, "tags=2000") {
		t.Fatalf("sign line lost the tag count: %q", line)
	}
}
