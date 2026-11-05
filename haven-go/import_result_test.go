package main

import (
	"strings"
	"testing"
)

func TestImportResultCompleteWithCounts(t *testing.T) {
	o := newImportOutcome()
	o.relaysChecked([]string{"wss://a", "wss://b", "wss://c"}, []string{"wss://a", "wss://b"}, "")
	o.observe("2026/11/05 02:40:00 ✅ owner note import complete! Imported 1234 notes")
	o.observe("2026/11/05 02:41:00 📦 imported 56 tagged notes")
	o.observe("✅ tagged import complete")
	// wss://c never answered the connect check: never read from, so partial
	// with its whole range unread (Tron, background risks 9), not complete.
	want := "IMPORT_RESULT status=partial reason=relays_unreachable owner=1234 tagged=56 relays=2/3 other_vault=none unread=1"
	if got := o.line(); got != want {
		t.Fatalf("got %q\nwant %q", got, want)
	}
	all := newImportOutcome()
	all.relaysChecked([]string{"wss://a", "wss://b"}, []string{"wss://a", "wss://b"}, "")
	if got := all.line(); got != "IMPORT_RESULT status=complete reason=ok owner=0 tagged=0 relays=2/2 other_vault=none unread=0" {
		t.Fatalf("every seed answered: got %q", got)
	}
}

// The exact cut lines import_owner.go and import.go print today.
func TestImportResultPartialReasons(t *testing.T) {
	o := newImportOutcome()
	o.observe("⚠️ reading [wss://a] window by window passed 15m0s; stopped at 2024-01-01 with 10 notes")
	o.observe("⚠️ 1 relay(s) stopped partway through 2024-01-01 to 2024-01-11; their older notes there may be missing: [wss://a]")
	o.observe("⚠️ wss://b answered nothing, or went quiet without finishing, for 3 windows in a row; not asking it again")
	o.observe("⚠️ negentropy import wss://a: 3 of 9 listed notes didn't come; 2 still missing after asking again")
	o.observe("⚠️ Failed to import 4 notes")
	o.observe("🚫 Timeout after 2m0s while importing tagged notes")
	o.observe("⚠️ reading [wss://c] window by window passed 15m0s; stopped at 2023-06-01 with 0 notes")
	status, reason := o.status()
	if status != "partial" {
		t.Fatalf("status %q", status)
	}
	want := "walk_deadline,relay_stopped_partway,relay_dropped,notes_missing,notes_failed,tagged_timeout"
	if reason != want {
		t.Fatalf("reason %q, want %q", reason, want)
	}
}

func TestImportResultOtherVault(t *testing.T) {
	const vault = "ws://127.0.0.1:41234/tok"
	reached := newImportOutcome()
	reached.relaysChecked([]string{"wss://a", vault}, []string{"wss://a", vault}, vault)
	if s, _ := reached.status(); s != "complete" || !strings.HasSuffix(reached.line(), "other_vault=reached unread=0") {
		t.Fatalf("reached: %s", reached.line())
	}
	missed := newImportOutcome()
	missed.relaysChecked([]string{"wss://a", vault}, []string{"wss://a"}, vault)
	s, r := missed.status()
	if s != "partial" || r != "other_vault_not_reached" || !strings.HasSuffix(missed.line(), "other_vault=not_reached unread=0") {
		t.Fatalf("missed: %s", missed.line())
	}
}

func TestImportResultFailedBeatsEverything(t *testing.T) {
	o := newImportOutcome()
	o.cut("walk_deadline")
	o.cancel()
	o.observe("🚫 failed to init import DBs: boom")
	o.fail("panic") // the first reason stays
	if s, r := o.status(); s != "failed" || r != "db_init" {
		t.Fatalf("got %s %s", s, r)
	}
	c := newImportOutcome()
	c.cut("walk_deadline")
	c.cancel()
	if s, r := c.status(); s != "cancelled" || r != "cancelled" {
		t.Fatalf("got %s %s", s, r)
	}
}

// No seed relay answered: a failed result, not "complete" (it used to be).
func TestImportResultNoSeedRelay(t *testing.T) {
	o := newImportOutcome()
	o.relaysChecked([]string{"wss://a"}, nil, "")
	o.fail("no_seed_relay")
	want := "IMPORT_RESULT status=failed reason=no_seed_relay owner=0 tagged=0 relays=0/1 other_vault=none unread=1"
	if got := o.line(); got != want {
		t.Fatalf("got %q", got)
	}
}

func TestImportResultFinishStoresLastLineOnce(t *testing.T) {
	o := newImportOutcome()
	currentImport.Store(o)
	observeImportLine("✅ owner note import complete! Imported 7 notes")
	o.finish()
	if currentImport.Load() != nil {
		t.Fatal("still collecting after finish")
	}
	observeImportLine("✅ owner note import complete! Imported 99 notes") // after the end: ignored
	got, _ := lastImportResult.Load().(string)
	if !strings.Contains(got, "status=complete") || !strings.Contains(got, "owner=7 ") {
		t.Fatalf("last %q", got)
	}
	// The result line itself never feeds a collector.
	o2 := newImportOutcome()
	o2.observe("📋 IMPORT_RESULT status=failed reason=db_init owner=0 tagged=0 relays=0/0 other_vault=none")
	if s, _ := o2.status(); s != "complete" {
		t.Fatalf("result line was read back: %s", s)
	}
}
