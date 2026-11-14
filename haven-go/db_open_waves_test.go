package main

import (
	"reflect"
	"testing"
)

func TestDBOpenWavesPutsTheVaultStoresFirst(t *testing.T) {
	got := dbOpenWaves([]string{"private", "chat", "outbox", "inbox", "blossom", "feed", "lists", "listsimport", "files"})
	want := [][]string{
		{"outbox", "inbox"},
		{"private", "chat", "blossom", "feed", "lists", "listsimport", "files"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("waves = %v, want %v", got, want)
	}
}

func TestDBOpenWavesDropsEmptyWaves(t *testing.T) {
	if got := dbOpenWaves([]string{"chat", "lists"}); !reflect.DeepEqual(got, [][]string{{"chat", "lists"}}) {
		t.Fatalf("no vault stores: %v", got)
	}
	if got := dbOpenWaves([]string{"inbox"}); !reflect.DeepEqual(got, [][]string{{"inbox"}}) {
		t.Fatalf("vault store only: %v", got)
	}
	if got := dbOpenWaves(nil); len(got) != 0 {
		t.Fatalf("nothing: %v", got)
	}
}

// Every store a start asks for opens and gets its global, whether it opened
// in the first wave or the second.
func TestGranularInitDBsOpensEveryStoreInWaves(t *testing.T) {
	t.Chdir(t.TempDir())
	names := []string{"private", "chat", "outbox", "inbox", "blossom", "feed", "lists", "listsimport", "files"}
	if err := GranularInitDBs(names); err != nil {
		t.Fatal(err)
	}
	defer CloseDBs()
	for _, name := range names {
		if dbs[name] == nil {
			t.Fatalf("%s not registered", name)
		}
	}
	for name, g := range map[string]DBBackend{
		"private": privateDB, "chat": chatDB, "outbox": outboxDB, "inbox": inboxDB, "blossom": blossomDB,
		"feed": feedDB, "lists": listsDB, "listsimport": listsImportDB, "files": filesDB,
	} {
		if g == nil {
			t.Fatalf("%s global not set", name)
		}
	}
}

func TestStartupMarkCountsFromProcessStart(t *testing.T) {
	if processStart.IsZero() {
		t.Fatal("no process start")
	}
	if osStart, ok := osProcessStart(); ok && !osStart.Equal(processStart) {
		t.Fatalf("process start %v != os start %v", processStart, osStart)
	}
}
