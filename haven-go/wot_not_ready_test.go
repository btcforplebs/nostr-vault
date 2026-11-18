package main

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/nbd-wtf/go-nostr"
)

// The relay answers before background setup installs the web of trust
// (#2054). A WoT-gated query or event in that window used to panic on a nil
// model and kill the app (Moto relaunch aborts, 2026-11-17). Runs in a fresh
// process, since tests in this package install a model.
func TestWotGatesBeforeTheModelLoads(t *testing.T) {
	if os.Getenv("HAVEN_WOT_NOT_READY_CHILD") == "1" {
		ctx := context.Background()
		if reject, _ := MustBeInWotToQuery(ctx, nostr.Filter{}); !reject {
			t.Fatal("a query before the WoT loads must be refused")
		}
		if reject, _ := MustBeInWotToPost(ctx, &nostr.Event{PubKey: "ab"}); !reject {
			t.Fatal("an event before the WoT loads must be refused")
		}
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestWotGatesBeforeTheModelLoads$")
	cmd.Env = append(os.Environ(), "HAVEN_WOT_NOT_READY_CHILD=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("WoT gates before the model loads: %v\n%s", err, out)
	}
}
