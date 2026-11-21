//go:build !wasm

package main

import (
	"context"
	"strings"
	"testing"
	"time"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/nbd-wtf/go-nostr"
)

func asSmallAddressSpace(t *testing.T, small bool) {
	t.Helper()
	old := smallAddressSpace
	smallAddressSpace = small
	t.Cleanup(func() { smallAddressSpace = old })
}

func vlogFileSizeFor(t *testing.T, goos string) int64 {
	t.Helper()
	s := newBadgerStoreFor(t.TempDir(), goos)
	return s.BadgerOptionsModifier(badgerdb.DefaultOptions("")).ValueLogFileSize
}

// Only a 32-bit Android build gets the smaller value-log files, and the
// memtable is the same everywhere on a phone (lowering it bricks a store).
func TestSmallAddressSpaceOnlyShrinksValueLogsOn32BitAndroid(t *testing.T) {
	asSmallAddressSpace(t, false)
	if got := vlogFileSizeFor(t, "android"); got != 16<<20 {
		t.Fatalf("64-bit android value log = %d, want 16 MiB", got)
	}
	asSmallAddressSpace(t, true)
	if got := vlogFileSizeFor(t, "android"); got != 8<<20 {
		t.Fatalf("32-bit android value log = %d, want 8 MiB", got)
	}
	if got := vlogFileSizeFor(t, "ios"); got != 16<<20 {
		t.Fatalf("ios value log = %d, want 16 MiB", got)
	}
	if got := vlogFileSizeFor(t, "darwin"); got != 64<<20 {
		t.Fatalf("mac value log = %d, want 64 MiB", got)
	}
	s := newBadgerStoreFor(t.TempDir(), "android")
	if got := s.BadgerOptionsModifier(badgerdb.DefaultOptions("")).MemTableSize; got != 8<<20 {
		t.Fatalf("32-bit android memtable = %d, want 8 MiB (never lower it)", got)
	}
}

func TestNeedsTidy(t *testing.T) {
	const mib = int64(1 << 20)
	cases := []struct {
		name  string
		small bool
		vlogs int
		bytes int64
		want  bool
	}{
		{"64-bit, 25 thin files", false, 25, 25 * mib, false},
		{"64-bit, 256 files", false, 256, 256 * mib, false},
		{"64-bit, 257 files", false, 257, 257 * mib, true},
		{"32-bit, 24 thin files", true, 24, 24 * mib, false},
		{"32-bit, 25 thin files", true, 25, 25 * mib, true},
		{"32-bit, 25 full files: a copy would not make fewer", true, 25, 25 * 8 * mib, false},
		{"32-bit, 257 full files", true, 257, 257 * 8 * mib, true},
		{"32-bit, no files", true, 0, 0, false},
	}
	for _, c := range cases {
		asSmallAddressSpace(t, c.small)
		if got := needsTidy(c.vlogs, c.bytes); got != c.want {
			t.Errorf("%s: needsTidy = %v, want %v", c.name, got, c.want)
		}
	}
}

// A store written with 16 MiB value-log files (every 32-bit install so far)
// opens with the 8 MiB setting and still has its events, big ones included.
func TestSmallAddressSpaceOpensAStoreWrittenWithBiggerFiles(t *testing.T) {
	dir := t.TempDir()
	sk := nostr.GeneratePrivateKey()
	big := strings.Repeat("x", 4<<10) // over the 1 KB value threshold: value log
	now := time.Now().Unix()

	asSmallAddressSpace(t, false)
	s := newBadgerStoreFor(dir, "android")
	if err := s.Init(); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{}
	for i := range 40 {
		ev := signedAt(t, sk, 1, big+strings.Repeat("y", i), now-int64(i))
		if err := s.SaveEvent(context.Background(), ev); err != nil {
			t.Fatal(err)
		}
		want[ev.ID] = true
	}
	s.Close()

	asSmallAddressSpace(t, true)
	s = newBadgerStoreFor(dir, "android")
	if err := s.Init(); err != nil {
		t.Fatalf("open with the 32-bit sizes: %v", err)
	}
	later := signedAt(t, sk, 1, big+"later", now+1)
	if err := s.SaveEvent(context.Background(), later); err != nil {
		t.Fatal(err)
	}
	want[later.ID] = true
	ch, err := s.QueryEvents(context.Background(), nostr.Filter{Kinds: []int{1}, Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for ev := range ch {
		if len(ev.Content) < len(big) {
			t.Fatalf("event %s came back short", ev.ID)
		}
		got[ev.ID] = true
	}
	s.Close()
	if !sameIDs(got, want) {
		t.Fatalf("got %d events, want %d", len(got), len(want))
	}
}

// The lower count tidies a 32-bit store that many opens left thin files in.
func TestSmallAddressSpaceTidiesAtTheLowerCount(t *testing.T) {
	dir, kept := tidyFixture(t, 30) // sets badgerTidyMaxVlogs to 8 for the build
	badgerTidyMaxVlogs = 256        // tidyFixture's cleanup restores it
	before := vlogCount(t, dir)
	if before <= smallSpaceTidyMaxVlogs {
		t.Fatalf("fixture has %d value-log files, want more than %d", before, smallSpaceTidyMaxVlogs)
	}

	asSmallAddressSpace(t, false)
	res, err := tidyBadgerDir(dir, newBadgerStoreFor(dir, "android").BadgerOptionsModifier)
	if err != nil || res.Tidied {
		t.Fatalf("64-bit: tidied=%v err=%v, want left alone", res.Tidied, err)
	}

	asSmallAddressSpace(t, true)
	res, err = tidyBadgerDir(dir, newBadgerStoreFor(dir, "android").BadgerOptionsModifier)
	if err != nil || !res.Tidied {
		t.Fatalf("32-bit: tidied=%v skipped=%q err=%v, want tidied", res.Tidied, res.SkippedBecause, err)
	}
	if after := vlogCount(t, dir); after >= before {
		t.Fatalf("value-log files %d -> %d, want fewer", before, after)
	}
	if got := storedIDs(t, dir); !sameIDs(got, kept) {
		t.Fatalf("after the tidy: %d events, want %d", len(got), len(kept))
	}
}
