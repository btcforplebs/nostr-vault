package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// The engine side of docs/fixtures/mesh-copy/: every case there, here.

func loadCopyFixture(t *testing.T, name string, into any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "docs", "fixtures", "mesh-copy", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

func TestCopyManifestFixtures(t *testing.T) {
	var fx struct {
		Owner string
		Cases []struct {
			Name     string
			Manifest copyManifest
			Expect   struct {
				OK    bool
				Error string
			}
		}
	}
	loadCopyFixture(t, "manifest-v2-cases.json", &fx)
	if len(fx.Cases) < 10 {
		t.Fatalf("positive control: only %d cases read", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		got := copyManifestError(c.Manifest, fx.Owner, map[string]struct{}{fx.Owner: {}})
		if (got == "") != c.Expect.OK || got != c.Expect.Error {
			t.Errorf("%s: got %q, want ok=%v error=%q", c.Name, got, c.Expect.OK, c.Expect.Error)
		}
	}
}

func TestCopyChunkStateFixtures(t *testing.T) {
	var fx struct {
		Cases []struct {
			Name     string
			Manifest copyManifest
			State    *copyState
			Expect   struct {
				Restart bool
				Need    map[string][]int
			}
		}
		Failures []struct {
			Name   string
			Before int
			Expect struct {
				Failures int
				Stop     bool
				Error    string
			}
		}
	}
	loadCopyFixture(t, "chunk-state-cases.json", &fx)
	for _, c := range fx.Cases {
		restart, need := copyPlan(c.Manifest, c.State)
		if restart != c.Expect.Restart || !reflect.DeepEqual(need, c.Expect.Need) {
			t.Errorf("%s: got restart=%v need=%v, want %v %v", c.Name, restart, need, c.Expect.Restart, c.Expect.Need)
		}
	}
	for _, c := range fx.Failures {
		n, stop := copyChunkFailed(c.Before)
		if n != c.Expect.Failures || stop != c.Expect.Stop {
			t.Errorf("%s: got %d stop=%v", c.Name, n, stop)
		}
	}
	if len(fx.Cases) == 0 || len(fx.Failures) == 0 {
		t.Fatal("positive control: no cases read")
	}
}

func TestCopyProgressLineFixtures(t *testing.T) {
	var fx struct {
		Cases []struct {
			Line   string
			Expect *struct {
				Stage  string
				Part   string
				Bytes  [2]int64
				Items  [2]int64
				Source string
				Error  string
			}
		}
	}
	loadCopyFixture(t, "progress-v2-lines.json", &fx)
	for _, c := range fx.Cases {
		got, ok := parseCopyLine(c.Line)
		if c.Expect == nil {
			if ok {
				t.Errorf("%q: read as %+v, want refused", c.Line, got)
			}
			continue
		}
		want := copyLine{Stage: c.Expect.Stage, Part: c.Expect.Part, Bytes: c.Expect.Bytes, Items: c.Expect.Items, Source: c.Expect.Source, Error: c.Expect.Error}
		if !ok || got != want {
			t.Errorf("%q: got %+v ok=%v, want %+v", c.Line, got, ok, want)
			continue
		}
		// What the engine writes reads back the same.
		if again, ok := parseCopyLine(formatCopyLine(got)); !ok || again != got {
			t.Errorf("%q: format/parse round trip gave %+v", c.Line, again)
		}
	}
}

func TestCopySettingsAllowlistMatchesFixture(t *testing.T) {
	var fx struct {
		Keys map[string]struct {
			Type     string
			Min, Max int
		}
	}
	loadCopyFixture(t, "settings-allowlist.json", &fx)
	if len(fx.Keys) != len(copySettingsAllowlist) {
		t.Fatalf("fixture has %d keys, engine %d", len(fx.Keys), len(copySettingsAllowlist))
	}
	for k, want := range fx.Keys {
		got, ok := copySettingsAllowlist[k]
		if !ok || got.Type != want.Type || got.Min != want.Min || got.Max != want.Max {
			t.Errorf("%s: engine %+v, fixture %+v", k, got, want)
		}
	}
}

func TestCopySettingsRefuseFixtures(t *testing.T) {
	var fx struct {
		Now   int64
		Cases []struct {
			Name     string
			Settings json.RawMessage
			Expect   struct {
				OK     bool
				Reason string
			}
		}
		NewestWins []struct {
			Name   string
			Mine   *int64
			Theirs *int64
			Expect string
		} `json:"newest_wins"`
	}
	loadCopyFixture(t, "settings-refuse-cases.json", &fx)
	refused := 0
	for _, c := range fx.Cases {
		got := copySettingsRefusal(c.Settings, time.Unix(fx.Now, 0))
		if (got == "") != c.Expect.OK || got != c.Expect.Reason {
			t.Errorf("%s: got %q, want ok=%v reason=%q", c.Name, got, c.Expect.OK, c.Expect.Reason)
		}
		if got != "" {
			refused++
		}
	}
	if refused < 5 {
		t.Fatalf("positive control: only %d cases refused", refused)
	}
	for _, c := range fx.NewestWins {
		var mine, theirs int64
		if c.Mine != nil {
			mine = *c.Mine
		}
		if c.Theirs != nil {
			theirs = *c.Theirs
		}
		got := "mine"
		if copySettingsNewer(mine, theirs) {
			got = "theirs"
		}
		if got != c.Expect {
			t.Errorf("%s: got %s, want %s", c.Name, got, c.Expect)
		}
	}
}

func TestCopyOwnMediaFixtures(t *testing.T) {
	var fx struct {
		Owner   string
		Records []struct {
			SHA256 string
			Pubkey string
		}
		Events []struct {
			Name    string
			Pubkey  string
			Kind    int
			Content string
			Tags    nostr.Tags
		}
		ExpectInMedia []string          `json:"expect_in_media"`
		ExpectLeftOut map[string]string `json:"expect_left_out"`
	}
	loadCopyFixture(t, "media-own-uploads-cases.json", &fx)
	records := map[string]string{}
	for _, r := range fx.Records {
		records[r.SHA256] = r.Pubkey
	}
	// fx.Events name some of the files; the rule must not care (contract §4).
	got := copyOwnMedia(records, map[string]bool{fx.Owner: true})
	for _, sha := range fx.ExpectInMedia {
		if !got[sha] {
			t.Errorf("%s: own upload left out", sha[:8])
		}
	}
	for sha, why := range fx.ExpectLeftOut {
		if got[sha] {
			t.Errorf("%s (%s) is in the media part", sha[:8], why)
		}
	}
	if len(got) != len(fx.ExpectInMedia) {
		t.Errorf("media part has %d files, want %d", len(got), len(fx.ExpectInMedia))
	}
}
