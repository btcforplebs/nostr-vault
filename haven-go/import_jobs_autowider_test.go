package main

import (
	"context"
	"sync"
	"testing"
)

// The first-run gap (Logen, 2026-11-12): setup brought in the user's own
// notes and lists, and the wider web waited for a button most people never
// found, so Underrated stayed empty and Discover blank. Setup ending (done or
// partial) now starts wider_network once; failed, cancelled or cut setups do
// not, and a wider web the user already ran or cancelled is left alone.
func TestJobsSetupStartsTheWiderWebByItself(t *testing.T) {
	cases := []struct {
		name        string
		setupFails  bool
		widerBefore string
		want        int
	}{
		{"setup done, wider never ran", false, jobNever, 1},
		{"setup failed", true, jobNever, 0},
		{"wider already done", false, jobDone, 0},
		{"wider cancelled by the user", false, jobCancelled, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			jobsSetup(t, 30, "wss://a.example")
			var mu sync.Mutex
			ran := map[string]int{}
			prevRun := runJob
			runJob = func(_ context.Context, _ func(string, func()), name string, res *jobResult) {
				mu.Lock()
				ran[name]++
				mu.Unlock()
				if name == jobSetup && tc.setupFails {
					res.failReason = "no_relay"
				}
			}
			t.Cleanup(func() { runJob = prevRun })
			updateJob(func(f *jobsFile) { f.job(jobWiderNetwork).Status = tc.widerBefore })

			runJobAndWait(t, context.Background(), jobSetup, false)
			waitIdle()

			mu.Lock()
			got := ran[jobWiderNetwork]
			mu.Unlock()
			if got != tc.want {
				t.Fatalf("wider_network ran %d times, want %d", got, tc.want)
			}
			if tc.want == 1 {
				if w := readJobs(t).job(jobWiderNetwork); w.Status != jobDone {
					t.Fatalf("wider_network %s after the auto start, want done", w.Status)
				}
				if d := func() int { config.WotDepth = 3; return effectiveWotDepth() }(); d != 3 {
					t.Fatalf("depth %d after the auto start, want the full 3", d)
				}
			}
		})
	}
}

// The relay stopping under setup (a cut) waits for the resume; the wider web
// starts after that resumed setup ends, not before.
func TestJobsCutSetupDoesNotStartTheWiderWeb(t *testing.T) {
	jobsSetup(t, 30, "wss://a.example")
	var mu sync.Mutex
	ran := map[string]int{}
	prevRun := runJob
	ctx, cancel := context.WithCancel(context.Background())
	runJob = func(_ context.Context, _ func(string, func()), name string, _ *jobResult) {
		mu.Lock()
		ran[name]++
		mu.Unlock()
		if name == jobSetup {
			cancel()
		}
	}
	t.Cleanup(func() { runJob = prevRun })
	runJobAndWait(t, ctx, jobSetup, false)
	waitIdle()
	mu.Lock()
	defer mu.Unlock()
	if ran[jobWiderNetwork] != 0 {
		t.Fatal("the wider web started under a cut setup")
	}
	if s := readJobs(t).job(jobSetup); s.Status != jobRunning {
		t.Fatalf("cut setup is %s, want running (resumes next start)", s.Status)
	}
}
