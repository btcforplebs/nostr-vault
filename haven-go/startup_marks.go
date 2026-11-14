package main

import (
	"log"
	"time"
)

// startupMark logs one "⏱ startup <step> +<ms>ms" line: milliseconds since
// this process started, so a relay.log pulled off a phone shows where a cold
// start spends its time. The app writes the same shape from Swift
// (StartupMarks.swift), counted from the same process start.
func startupMark(step string) {
	log.Printf("⏱ startup %s +%dms", step, time.Since(processStart).Milliseconds())
}

// processStart is when the OS started this process (the app on iPhone, iPad
// and Mac: Go runs in-process). Falls back to when Go first ran.
var processStart = func() time.Time {
	if t, ok := osProcessStart(); ok {
		return t
	}
	return time.Now()
}()
