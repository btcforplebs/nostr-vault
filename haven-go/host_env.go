package main

import (
	"os"
	"sync"

	"github.com/joho/godotenv"
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
// value first, then the real process environment (the standalone binary's
// shell, the wasm entry, tests' t.Setenv), then the .env file.
var hostEnv = struct {
	sync.RWMutex
	m map[string]string
}{m: map[string]string{}}

// dotEnv is the .env file, read into Go's memory. godotenv.Load would
// os.Setenv every key the process lacks, and with cgo that is libc
// setenv(3) again: the Apple apps write ~90 settings to .env before each
// relay start, so Load made ~90 unlocked environ writes on the launch path.
// The process environment still beats .env, as it did under Load.
var dotEnv = struct {
	sync.RWMutex
	m map[string]string
}{}

// loadDotEnv replaces the in-memory .env with the file at path. A missing or
// unreadable file means no .env values, as Load's ignored error did.
func loadDotEnv(path string) {
	m, err := godotenv.Read(path)
	if err != nil {
		m = nil
	}
	dotEnv.Lock()
	dotEnv.m = m
	dotEnv.Unlock()
}

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
	if value, ok := os.LookupEnv(key); ok {
		return value, true
	}
	dotEnv.RLock()
	value, ok = dotEnv.m[key]
	dotEnv.RUnlock()
	return value, ok
}

// hostGetenv is os.Getenv for relay settings.
func hostGetenv(key string) string {
	value, _ := lookupHostEnv(key)
	return value
}
