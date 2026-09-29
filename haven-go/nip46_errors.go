package main

import (
	"context"
	"strings"
)

// classifyNIP46Error turns a failed go-nostr BunkerClient call into the code
// the app shows: "rejected:<signer message>" when the signer answered with an
// error, "offline" when no relay could be reached, "timeout" when the call ran
// out its context, "error:<detail>" otherwise. go-nostr reports a signer
// refusal as "response error: …", an unreachable relay as "couldn't connect
// to any relay", and an expired context as "context canceled".
func classifyNIP46Error(ctx context.Context, err error) string {
	msg := err.Error()
	switch {
	case strings.HasPrefix(msg, "response error: "):
		return "rejected:" + strings.TrimPrefix(msg, "response error: ")
	case strings.Contains(msg, "couldn't connect to any relay"):
		return "offline"
	case ctx.Err() != nil:
		return "timeout"
	default:
		return "error:" + msg
	}
}

// nip46ConnectConfirmed reports whether a connect result came from the signer
// holding our pairing secret. NIP-46 lets a signer answer "ack" or echo the
// secret back (Clave and nsec.app echo it). Without a secret — a reconnect of
// an already-paired client — there is nothing to check.
func nip46ConnectConfirmed(result, secret string) bool {
	if secret == "" {
		return true
	}
	return result == "ack" || result == secret
}
