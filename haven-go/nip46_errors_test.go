//go:build !cshared

package main

import (
	"context"
	"errors"
	"log/slog"
	"testing"
)

func TestClassifyNIP46Error(t *testing.T) {
	live := context.Background()
	expired, cancel := context.WithCancel(context.Background())
	cancel()
	timedOut, cancelTimeout := context.WithTimeout(context.Background(), 0)
	defer cancelTimeout()

	cases := []struct {
		name string
		ctx  context.Context
		err  error
		want string
	}{
		{"signer refused", live, errors.New("response error: user rejected"), "rejected:user rejected"},
		{"refusal wins over an expired context", expired, errors.New("response error: denied"), "rejected:denied"},
		{"no relay", expired, errors.New("couldn't connect to any relay"), "offline"},
		{"ran out of time", timedOut, errors.New("context canceled"), "timeout"},
		{"session torn down", expired, errors.New("context canceled"), "disconnected"},
		{"anything else", live, errors.New("boom"), "error:boom"},
	}
	for _, c := range cases {
		if got := classifyNIP46Error(c.ctx, c.err); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestNIP46ConnectConfirmed(t *testing.T) {
	cases := []struct {
		result, secret string
		want           bool
	}{
		{"ack", "s3cret", true},
		{"s3cret", "s3cret", true}, // Clave echoes the secret
		{"other", "s3cret", false}, // not the signer we paired with
		{"", "s3cret", false},
		{"anything", "", true}, // reconnect: no secret to check
	}
	for _, c := range cases {
		if got := nip46ConnectConfirmed(c.result, c.secret); got != c.want {
			t.Errorf("result=%q secret=%q: got %v, want %v", c.result, c.secret, got, c.want)
		}
	}
}

func TestNIP46PingLogLevel(t *testing.T) {
	for _, kind := range []string{"timeout", "disconnected", "offline"} {
		if got := nip46PingLogLevel(kind); got != slog.LevelWarn {
			t.Errorf("%s: got %v, want WARN", kind, got)
		}
	}
	for _, kind := range []string{"rejected:denied", "error:boom", ""} {
		if got := nip46PingLogLevel(kind); got != slog.LevelError {
			t.Errorf("%q: got %v, want ERROR", kind, got)
		}
	}
}
