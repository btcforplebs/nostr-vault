//go:build !wasm

package main

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/dgraph-io/ristretto/v2/z"
)

// A store's files, tidied before it opens (Logen 2026-11-14, startup step 4).
//
// Badger starts a new value-log file on every open and keeps any that got a
// value, and it only rewrites a file that is mostly garbage, one per pass. A
// phone's inbox had 2,310 value-log files (2.27 GB) holding 128 MB of live
// events: every open maps each file, and deletes never gave the space back
// (badger_compact.go reclaims only a few files per round).
//
// So once a store has more than badgerTidyMaxVlogs value-log files, it is
// copied before it opens: the live keys (latest version, nothing deleted)
// are streamed into a fresh directory, both are counted key by key, and only
// when every count and the events' checksum match does the fresh copy take
// the old one's place. Anything else (an error, a count off, no space) keeps
// the old store exactly as it was and it opens as always. The count check
// keeps up by itself: a store tidies again once it has gathered that many
// files.
var badgerTidyMaxVlogs = 256 // a var for the tests

const (
	tidyNewSuffix   = ".tidy-new"
	tidyOldSuffix   = ".tidy-old"
	tidyStraySuffix = ".tidy-stray"
	tidyTrySuffix   = ".tidy-try"
	// A tidy cut off this many times (iOS suspended or killed the app
	// mid-copy) waits tidyRetryAfter before it is tried again, so a store too
	// big to copy in one launch doesn't cost every launch a full copy.
	tidyMaxTries   = 2
	tidyRetryAfter = 24 * time.Hour
)

// tidyCounts: keys per first byte (eventstore uses one byte per key type,
// raw events are 0) and a checksum over the raw events' keys and values.
type tidyCounts struct {
	Keys   [256]int
	Events uint64 // xor of fnv-64a(key, value) over prefix 0
}

func (c tidyCounts) total() int {
	n := 0
	for _, k := range c.Keys {
		n += k
	}
	return n
}

// tidyResult says what tidyBadgerDir did, for the log and the tests.
type tidyResult struct {
	Tidied         bool
	VlogsBefore    int
	VlogsAfter     int
	BytesBefore    int64
	BytesAfter     int64
	KeysBefore     int
	KeysAfter      int
	Took           time.Duration
	SkippedBecause string
}

// recoverTidy finishes or undoes a swap a stopped process left halfway.
// Old and a complete store (MANIFEST) both present: the swap finished, the
// old goes. Only the old present, or beside a folder that is no store (made
// after the stop): the swap stopped between the renames, the folder is moved
// aside and the old comes back. A fresh copy left over was never swapped in,
// so it goes.
func recoverTidy(path string) error {
	old, fresh := path+tidyOldSuffix, path+tidyNewSuffix
	if _, err := os.Stat(old); err == nil {
		_, statErr := os.Stat(path)
		_, manifestErr := os.Stat(filepath.Join(path, "MANIFEST"))
		switch {
		case manifestErr == nil:
			if err := os.RemoveAll(old); err != nil {
				return err
			}
		case statErr == nil:
			stray := path + tidyStraySuffix
			if err := os.RemoveAll(stray); err != nil {
				return err
			}
			if err := os.Rename(path, stray); err != nil {
				return err
			}
			if err := os.Rename(old, path); err != nil {
				return err
			}
		case os.IsNotExist(statErr):
			if err := os.Rename(old, path); err != nil {
				return err
			}
		}
	}
	if _, err := os.Stat(fresh); err == nil {
		return os.RemoveAll(fresh)
	}
	return nil
}

// dirFiles counts the value-log files and sums the sizes in dir.
func dirFiles(dir string) (vlogs int, bytes int64, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, 0, err
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".vlog") {
			vlogs++
		}
		if info, err := e.Info(); err == nil {
			bytes += info.Size()
		}
	}
	return vlogs, bytes, nil
}

// countKeys counts db's live keys by first byte and checksums the events.
func countKeys(db *badgerdb.DB) (tidyCounts, error) {
	var c tidyCounts
	err := db.View(func(txn *badgerdb.Txn) error {
		opts := badgerdb.DefaultIteratorOptions
		opts.PrefetchValues = false
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			item := it.Item()
			key := item.Key()
			if len(key) == 0 {
				continue
			}
			c.Keys[key[0]]++
			if key[0] != 0 {
				continue
			}
			h := fnv.New64a()
			h.Write(key)
			if err := item.Value(func(v []byte) error { h.Write(v); return nil }); err != nil {
				return err
			}
			c.Events ^= h.Sum64()
		}
		return nil
	})
	return c, err
}

// tidyTestAfterCopy lets a test spoil the copy before it is checked.
var tidyTestAfterCopy func(*badgerdb.DB)

// tidyBadgerDir tidies the store at path if it has too many value-log files
// (see above). opts are the options the store opens with. It never returns
// with the store missing: on any error the old one stays where it was.
func tidyBadgerDir(path string, opts func(badgerdb.Options) badgerdb.Options) (tidyResult, error) {
	var res tidyResult
	if err := recoverTidy(path); err != nil {
		return res, fmt.Errorf("tidy: recover: %w", err)
	}
	vlogs, bytes, err := dirFiles(path)
	if err != nil {
		if os.IsNotExist(err) {
			res.SkippedBecause = "no store yet"
			return res, nil
		}
		return res, err
	}
	res.VlogsBefore, res.BytesBefore = vlogs, bytes
	if vlogs <= badgerTidyMaxVlogs {
		res.SkippedBecause = "few files"
		return res, nil
	}
	if !tidyTry(path) {
		res.SkippedBecause = "cut off before, waiting"
		return res, nil
	}
	start := time.Now()
	fresh := path + tidyNewSuffix

	if err := copyLiveKeys(path, fresh, opts, &res); err != nil {
		os.RemoveAll(fresh)
		return res, err
	}

	// Swap: old aside, fresh in, old gone. recoverTidy finishes or undoes a
	// stop between any two of these.
	old := path + tidyOldSuffix
	if err := os.Rename(path, old); err != nil {
		os.RemoveAll(fresh)
		return res, fmt.Errorf("tidy: set old aside: %w", err)
	}
	if err := os.Rename(fresh, path); err != nil {
		if rerr := os.Rename(old, path); rerr != nil {
			return res, fmt.Errorf("tidy: swap in: %v; put back: %w", err, rerr)
		}
		os.RemoveAll(fresh)
		return res, fmt.Errorf("tidy: swap in: %w", err)
	}
	if err := os.RemoveAll(old); err != nil {
		slog.Warn("tidy: old store left behind, removed next open", "path", old, "err", err)
	}
	os.Remove(path + tidyTrySuffix)
	res.VlogsAfter, res.BytesAfter, _ = dirFiles(path)
	res.Tidied = true
	res.Took = time.Since(start)
	return res, nil
}

// tidyTry counts a tidy attempt in a marker beside the store and says
// whether to make it: not when tidyMaxTries attempts within tidyRetryAfter
// never finished. A finished tidy removes the marker; an older one counts
// from zero again.
func tidyTry(path string) bool {
	marker := path + tidyTrySuffix
	tries := 0
	if info, err := os.Stat(marker); err == nil && time.Since(info.ModTime()) < tidyRetryAfter {
		if b, err := os.ReadFile(marker); err == nil {
			fmt.Sscanf(string(b), "%d", &tries)
		}
		if tries >= tidyMaxTries {
			return false
		}
	}
	if err := os.WriteFile(marker, []byte(fmt.Sprintf("%d\n", tries+1)), 0o600); err != nil {
		return false // can't count it: don't start what might never finish
	}
	return true
}

// copyLiveKeys streams src's live keys into a fresh store at dst and checks
// the two hold the same keys. Both are closed when it returns.
func copyLiveKeys(src, dst string, opts func(badgerdb.Options) badgerdb.Options, res *tidyResult) (err error) {
	open := func(dir string) (*badgerdb.DB, error) {
		o := badgerdb.DefaultOptions(dir)
		if opts != nil {
			o = opts(o)
		}
		return badgerdb.Open(o)
	}
	if err := os.RemoveAll(dst); err != nil {
		return err
	}
	from, err := open(src)
	if err != nil {
		return fmt.Errorf("tidy: open: %w", err)
	}
	defer func() {
		if cerr := from.Close(); cerr != nil && err == nil {
			err = fmt.Errorf("tidy: close: %w", cerr)
		}
	}()
	to, err := open(dst)
	if err != nil {
		return fmt.Errorf("tidy: open copy: %w", err)
	}
	defer func() {
		if cerr := to.Close(); cerr != nil && err == nil {
			err = fmt.Errorf("tidy: close copy: %w", cerr)
		}
	}()

	before, err := countKeys(from)
	if err != nil {
		return fmt.Errorf("tidy: count: %w", err)
	}

	sw := to.NewStreamWriter()
	if err := sw.Prepare(); err != nil {
		return fmt.Errorf("tidy: prepare: %w", err)
	}
	stream := from.NewStream()
	stream.LogPrefix = "tidy " + filepath.Base(src)
	// A phone's memory: four readers, 16 MB batches (defaults 8 and 100 MB).
	stream.NumGo = 4
	stream.MaxSize = 16 << 20
	stream.Send = func(buf *z.Buffer) error { return sw.Write(buf) }
	if err := stream.Orchestrate(context.Background()); err != nil {
		sw.Cancel()
		return fmt.Errorf("tidy: copy: %w", err)
	}
	if err := sw.Flush(); err != nil {
		return fmt.Errorf("tidy: flush: %w", err)
	}

	if tidyTestAfterCopy != nil {
		tidyTestAfterCopy(to)
	}
	after, err := countKeys(to)
	if err != nil {
		return fmt.Errorf("tidy: count copy: %w", err)
	}
	res.KeysBefore, res.KeysAfter = before.total(), after.total()
	if before != after {
		return errors.New("tidy: copy doesn't match, old store kept")
	}
	return nil
}

// Init tidies the store's files if they need it (above), then opens it. A
// tidy that fails only logs: the store opens as it was.
func (s *badgerStore) Init() error {
	res, err := tidyBadgerDir(s.Path, s.BadgerOptionsModifier)
	switch {
	case err != nil:
		slog.Warn("tidy: store kept as it was", "path", s.Path, "err", err)
	case res.Tidied:
		slog.Info(fmt.Sprintf("tidy: %s %d -> %d value-log files, %d -> %d MB, %d keys kept, %v",
			s.Path, res.VlogsBefore, res.VlogsAfter, res.BytesBefore>>20, res.BytesAfter>>20, res.KeysAfter, res.Took.Round(time.Millisecond)))
	}
	return s.BadgerBackend.Init()
}
