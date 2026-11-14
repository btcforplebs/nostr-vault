//go:build !darwin

package main

import "time"

// Android/Linux: when Go first ran (Android adds its own marks later).
func osProcessStart() (time.Time, bool) { return time.Time{}, false }
