package box

import (
	"fmt"
	"strings"
	"testing"
)

func TestLogRingWritesLinesAndWraps(t *testing.T) {
	l := NewLogRing(3)
	w := l.Writer("engine")
	fmt.Fprint(w, "one\ntw")
	fmt.Fprint(w, "o\r\nthree\n")
	if got := l.Read(0, 0); len(got.Lines) != 3 || got.Lines[1].Text != "two" || got.Last != 3 {
		t.Fatalf("lines: %+v", got)
	}
	fmt.Fprint(l.Writer("box"), "four\nfive\n")
	got := l.Read(0, 0)
	if len(got.Lines) != 3 || got.Lines[0].Text != "three" || got.Lines[2].Text != "five" || got.Lines[2].Source != "box" {
		t.Fatalf("wrapped: %+v", got)
	}
	if got := l.Read(1, 0); !got.Dropped || got.Lines[0].Seq != 3 {
		t.Fatalf("after 1 (pushed out): %+v", got)
	}
	if got := l.Read(4, 0); got.Dropped || len(got.Lines) != 1 || got.Lines[0].Text != "five" {
		t.Fatalf("after 4: %+v", got)
	}
	if got := l.Read(0, 2); len(got.Lines) != 2 || got.Lines[1].Text != "five" {
		t.Fatalf("newest 2: %+v", got)
	}
	if got := l.Read(5, 0); len(got.Lines) != 0 || got.Lines == nil {
		t.Fatalf("nothing new must be an empty list: %+v", got)
	}
}

func TestLogRingCutsLongLines(t *testing.T) {
	l := NewLogRing(4)
	fmt.Fprint(l.Writer("engine"), strings.Repeat("x", logLineMax*2)) // no newline at all
	got := l.Read(0, 0)
	if len(got.Lines) != 1 || len(got.Lines[0].Text) > logLineMax+len("…") {
		t.Fatalf("long: %d lines", len(got.Lines))
	}
}

// Logs are the first account's: a signed-in added account is refused.
func TestLogsFirstAccountOnly(t *testing.T) {
	srv, owner, member, _ := signedInAPI(t)
	fmt.Fprintln(BoxLog.Writer("box"), "logs route test line")
	code, out := call(t, srv, &owner, "GET", "/api/box/logs", nil)
	if code != 200 || out["last"].(float64) < 1 {
		t.Fatalf("owner: %d %v", code, out)
	}
	if code, _ := call(t, srv, &member, "GET", "/api/box/logs", nil); code != 403 {
		t.Fatalf("signed-in member: %d, want 403", code)
	}
}
