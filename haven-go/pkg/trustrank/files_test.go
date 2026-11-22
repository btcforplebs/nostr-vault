package trustrank

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// The "nothing newer" check reads only the start of the file: a file whose
// rows are cut off still gives its builtAt.
func TestResultBuiltAtReadsOnlyTheHeader(t *testing.T) {
	dir := t.TempDir()
	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(ResultPath(dir, pk(0)), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"account":"` + pk(0) + `","builtAt":1234,"version":2,"params":{},"maxHop":4,"people":[["` + pk(1) + `",50,2],[`)
	if got, err := ResultBuiltAt(dir, pk(0)); err != nil || got != 1234 {
		t.Fatalf("header of a file with cut-off rows: %d %v", got, err)
	}
	if _, err := ReadResult(dir, pk(0)); err == nil {
		t.Fatal("the whole read of that file must fail, or this test proves nothing")
	}
	// Fields in another order: still read (the rows are skipped, not kept).
	write(`{"people":[["` + pk(1) + `",50,2]],"builtAt":77,"account":"` + pk(0) + `"}`)
	if got, err := ResultBuiltAt(dir, pk(0)); err != nil || got != 77 {
		t.Fatalf("fields after people: %d %v", got, err)
	}
	// What the crawler writes.
	f := ResultFile{Account: pk(0), BuiltAt: 99, Version: 2, MaxHop: 3, People: [][3]any{{pk(1), 50.0, 2}}}
	if err := WriteHandoff(dir, f); err != nil {
		t.Fatal(err)
	}
	if got, err := ResultBuiltAt(dir, pk(0)); err != nil || got != 99 {
		t.Fatalf("a written result: %d %v", got, err)
	}
	for name, body := range map[string]string{
		"another account": `{"account":"` + pk(1) + `","builtAt":5}`,
		"no builtAt":      `{"account":"` + pk(0) + `"}`,
		"zero builtAt":    `{"account":"` + pk(0) + `","builtAt":0}`,
		"not an object":   `[1,2]`,
		"not JSON":        `nope`,
	} {
		write(body)
		if _, err := ResultBuiltAt(dir, pk(0)); !errors.Is(err, ErrBadResult) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := ResultBuiltAt(dir, pk(5)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("missing file: %v", err)
	}
	if _, err := ResultBuiltAt(dir, "../x"); !errors.Is(err, ErrBadResult) {
		t.Errorf("bad account: %v", err)
	}
}

// Signed-out accounts lose their result and checkpoint; kept ones, the
// shared list store and anything not named for an account stay.
func TestPruneAccountsRemovesOnlySignedOutOnes(t *testing.T) {
	dir := t.TempDir()
	touch := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	keep, gone := pk(1), pk(2)
	for _, a := range []string{keep, gone} {
		touch("wot_rank_" + a + ".json")
		touch("state_" + a + ".json")
	}
	touch("wot_rank_notakey.json")
	touch("state_v1.json")
	touch("wot_cache.json")
	if err := os.MkdirAll(filepath.Join(dir, "wot_deep"), 0o700); err != nil {
		t.Fatal(err)
	}
	touch("wot_deep/keys.bin")

	if got := PruneAccounts(dir, []string{keep}); !slices.Equal(got, []string{gone}) {
		t.Fatalf("pruned %v", got)
	}
	for _, name := range []string{"wot_rank_" + gone + ".json", "state_" + gone + ".json"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s must be gone: %v", name, err)
		}
	}
	for _, name := range []string{"wot_rank_" + keep + ".json", "state_" + keep + ".json", "wot_rank_notakey.json",
		"state_v1.json", "wot_cache.json", "wot_deep/keys.bin"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s must stay: %v", name, err)
		}
	}
	if got := PruneAccounts(dir, []string{keep}); len(got) != 0 {
		t.Fatalf("a second prune found %v", got)
	}
}
