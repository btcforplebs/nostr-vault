//go:build cshared

package main

import "C"

import (
	"context"
	"encoding/json"
	"log"
	"time"
)

// ComputeCatchUpNotesC answers the Catch Up feed (feed_catchup.go): the
// newest post of each person in follows (a JSON array of hex pubkeys, the
// active account's follow list), newest first. Same JSON shape as
// ComputePopularNotesC, score = created_at.
//
//export ComputeCatchUpNotesC
func ComputeCatchUpNotesC(follows *C.char) *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("ComputeCatchUpNotesC: recovered from panic: %v", r)
		}
	}()
	c := relayLC.current.Load()
	if c == nil || c.server == nil { // server == nil means import cycle
		return dvmErrorC("relay not running")
	}
	var list []string
	if follows != nil {
		if err := json.Unmarshal([]byte(C.GoString(follows)), &list); err != nil {
			return dvmErrorC("bad follow list")
		}
	}
	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
	defer cancel()
	return dvmResultC(computeCatchUpNotes(ctx, list))
}

// ComputeUnderratedNotesC answers the Underrated feed (feed_underrated.go).
// Same JSON shape as ComputePopularNotesC, except that an empty answer is
// {"reason": "web_incomplete" | "nothing_qualified" | "web_not_ready"}:
// the apps offer to build the wider network for the first.
//
//export ComputeUnderratedNotesC
func ComputeUnderratedNotesC() *C.char {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("ComputeUnderratedNotesC: recovered from panic: %v", r)
		}
	}()
	c := relayLC.current.Load()
	if c == nil || c.server == nil {
		return dvmErrorC("relay not running")
	}
	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
	defer cancel()
	notes, reason, err := computeUnderratedNotes(ctx)
	if err == nil && len(notes) == 0 && reason != "" {
		return C.CString(underratedEmptyJSON(reason))
	}
	return dvmResultC(notes, err)
}

func dvmErrorC(msg string) *C.char {
	result, _ := json.Marshal(map[string]string{"error": msg})
	return C.CString(string(result))
}

// dvmResultC encodes a local DVM feed answer, or {"error": ...}.
func dvmResultC(notes []PopularNote, err error) *C.char {
	if err != nil {
		return dvmErrorC(err.Error())
	}
	result, err := json.Marshal(notes)
	if err != nil {
		return dvmErrorC(err.Error())
	}
	return C.CString(string(result))
}
