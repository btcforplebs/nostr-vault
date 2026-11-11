package main

import (
	"os"
	"sync"
)

// hostEnv is the settings the embedding app (Android JNI, iOS/macOS Swift)
// hands the relay through SetHavenEnvC. It is Go-owned on purpose: writing
// them with os.Setenv also calls libc setenv(3), which reallocates the C
// `environ` array with no lock. The app's other threads read that array all
// the time (every Java DNS lookup goes through bionic getenv), so a setenv
// while they run is a use-after-free — the Android cold-launch SIGSEGV in
// getenv (RESEARCH/NV_ANDROID_GETENV_SIGSEGV_2026_11_10.md). Nothing outside
// haven-go reads these keys, so they never need to reach libc.
//
// Every relay setting is read through lookupHostEnv/hostGetenv: the host's
// value first, then the real process environment (.env via godotenv, the
// standalone binary's shell, the wasm entry, tests' t.Setenv).
var hostEnv = struct {
	sync.RWMutex
	m map[string]string
}{m: map[string]string{}}

// setHostEnv stores one host setting. It never touches the process
// environment.
func setHostEnv(key, value string) {
	hostEnv.Lock()
	hostEnv.m[key] = value
	hostEnv.Unlock()
}

// lookupHostEnv is os.LookupEnv for relay settings: a host-set value wins
// (an empty string counts as set, as it did with os.Setenv).
func lookupHostEnv(key string) (string, bool) {
	hostEnv.RLock()
	value, ok := hostEnv.m[key]
	hostEnv.RUnlock()
	if ok {
		return value, true
	}
	return os.LookupEnv(key)
}

// hostGetenv is os.Getenv for relay settings.
func hostGetenv(key string) string {
	value, _ := lookupHostEnv(key)
	return value
}
