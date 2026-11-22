package box

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// The box's log: the engine's output and havend's own, kept in memory for the
// web dashboard's Activity card and full logs in box mode (One Vault E4). The
// lines still go to stdout/stderr as before (journald, the store's log view).
//
// First account only: log lines name accounts, devices and addresses that
// other accounts on the box should not see.
func init() {
	handle("GET /api/box/logs", FirstAccount, func(_ *API, w http.ResponseWriter, r *http.Request, _ Caller, _ []byte) {
		q := r.URL.Query()
		after, _ := strconv.ParseInt(q.Get("after"), 10, 64)
		limit, _ := strconv.Atoi(q.Get("limit"))
		writeJSON(w, http.StatusOK, BoxLog.Read(after, limit))
	})
}

// BoxLog holds the newest lines from the engine (engine.go) and havend
// (cmd/havend: log.SetOutput).
var BoxLog = NewLogRing(2000)

const (
	logLineMax     = 2048 // longer lines are cut: one runaway line cannot fill the ring
	logReadDefault = 200
	logReadMax     = 1000
)

// LogLine is one line of the box's log. Seq grows by one per line for as long
// as havend runs; a client asks for lines after the last Seq it holds.
type LogLine struct {
	Seq    int64  `json:"seq"`
	At     int64  `json:"at"` // unix seconds
	Source string `json:"source"`
	Text   string `json:"text"`
}

// Logs is GET /api/box/logs?after=<seq>&limit=<n>: lines after seq, oldest
// first, at most limit (200 by default, 1000 at most). Without after, the
// newest limit lines. Last is the newest Seq the box has; Dropped says lines
// after `after` were already pushed out of the ring.
type Logs struct {
	Lines   []LogLine `json:"lines"`
	Last    int64     `json:"last"`
	Dropped bool      `json:"dropped,omitempty"`
}

// LogRing keeps the newest lines written through its writers.
type LogRing struct {
	mu    sync.Mutex
	lines []LogLine // ring, len == cap once full
	next  int       // where the next line goes once full
	seq   int64
	now   func() time.Time
}

func NewLogRing(n int) *LogRing {
	return &LogRing{lines: make([]LogLine, 0, n), now: time.Now}
}

func (l *LogRing) add(source, text string) {
	if len(text) > logLineMax {
		text = text[:logLineMax] + "…"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.seq++
	line := LogLine{Seq: l.seq, At: l.now().Unix(), Source: source, Text: text}
	if len(l.lines) < cap(l.lines) {
		l.lines = append(l.lines, line)
		return
	}
	l.lines[l.next] = line
	l.next = (l.next + 1) % len(l.lines)
}

// ordered: the ring oldest first. Caller holds mu.
func (l *LogRing) ordered() []LogLine {
	out := make([]LogLine, 0, len(l.lines))
	out = append(out, l.lines[l.next:]...)
	return append(out, l.lines[:l.next]...)
}

func (l *LogRing) Read(after int64, limit int) Logs {
	if limit <= 0 {
		limit = logReadDefault
	}
	if limit > logReadMax {
		limit = logReadMax
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	all := l.ordered()
	out := Logs{Last: l.seq, Lines: []LogLine{}}
	if after <= 0 {
		if len(all) > limit {
			all = all[len(all)-limit:]
		}
		out.Lines = append(out.Lines, all...)
		return out
	}
	if len(all) > 0 && all[0].Seq > after+1 {
		out.Dropped = true
	}
	for _, line := range all {
		if line.Seq > after {
			out.Lines = append(out.Lines, line)
			if len(out.Lines) == limit {
				break
			}
		}
	}
	return out
}

// Writer is an io.Writer that files each complete line under source. A line
// split across writes is joined; a trailing partial line waits for its end.
func (l *LogRing) Writer(source string) io.Writer {
	return &logWriter{ring: l, source: source}
}

type logWriter struct {
	ring    *LogRing
	source  string
	mu      sync.Mutex
	partial []byte
}

func (w *logWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.partial = append(w.partial, p...)
	for {
		i := bytes.IndexByte(w.partial, '\n')
		if i < 0 {
			break
		}
		w.ring.add(w.source, string(bytes.TrimRight(w.partial[:i], "\r")))
		w.partial = w.partial[i+1:]
	}
	if len(w.partial) > logLineMax {
		w.ring.add(w.source, string(w.partial))
		w.partial = nil
	}
	if len(w.partial) == 0 {
		w.partial = nil // let the backing array go
	}
	return len(p), nil
}

var (
	engineOutOnce              sync.Once
	engineStdout, engineStderr *os.File
)

// engineOutputs: the engine's stdout and stderr. Each is the write end of a
// pipe havend keeps open for its whole life, read by one goroutine that
// copies to havend's own stdout/stderr and into BoxLog. A file, not an
// io.Writer: given a Writer, exec makes its own pipe and cmd.Wait waits for
// it to close, so a child the engine left behind holding it would keep Wait
// from returning and the engine from being restarted. Without a pipe (out of
// files) the engine writes to havend's own output as before, unlogged.
func engineOutputs() (stdout, stderr *os.File) {
	engineOutOnce.Do(func() {
		engineStdout = logPipe(os.Stdout)
		engineStderr = logPipe(os.Stderr)
	})
	return engineStdout, engineStderr
}

func logPipe(also *os.File) *os.File {
	r, w, err := os.Pipe()
	if err != nil {
		return also
	}
	go io.Copy(io.MultiWriter(also, BoxLog.Writer("engine")), r)
	return w
}
