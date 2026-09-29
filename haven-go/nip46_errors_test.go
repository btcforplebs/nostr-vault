//go:build !cshared

package main

import (
	"context"
	"errors"
	"testing"
)

func TestClassifyNIP46Error(t *testing.T) {
	live := context.Background()
	expired, cancel := context.WithCancel(context.Background())
	cancel()

	cases := []struct {
		name string
		ctx  context.Context
		err  error
		want string
	}{
		{"signer refused", live, errors.New("response error: user rejected"), "rejected:user rejected"},
		{"refusal wins over an expired context", expired, errors.New("response error: denied"), "rejected:denied"},
		{"no relay", expired, errors.New("couldn't connect to any relay"), "offline"},
		{"ran out of time", expired, errors.New("context canceled"), "timeout"},
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
