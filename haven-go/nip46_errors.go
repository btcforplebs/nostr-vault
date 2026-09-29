package main

import (
	"context"
	"errors"
	"strings"
)

// classifyNIP46Error turns a failed go-nostr BunkerClient call into the code
// the app shows: "rejected:<signer message>" when the signer answered with an
// error, "offline" when no relay could be reached, "timeout" when the call ran
// out its deadline, "disconnected" when the session was cancelled under it,
// "error:<detail>" otherwise. go-nostr reports a signer
// refusal as "response error: …", an unreachable relay as "couldn't connect
// to any relay", and an expired context as "context canceled".
func classifyNIP46Error(ctx context.Context, err error) string {
	msg := err.Error()
	switch {
	case strings.HasPrefix(msg, "response error: "):
		return "rejected:" + strings.TrimPrefix(msg, "response error: ")
	case strings.Contains(msg, "couldn't connect to any relay"):
		return "offline"
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return "timeout"
	case ctx.Err() != nil:
		// The session was torn down (disconnect, account switch, reconnect)
		// while the call was waiting: not the signer's fault.
		return "disconnected"
	default:
		return "error:" + msg
	}
}

// nip46ConnectConfirmed reports whether a connect result is one NIP-46
// defines: "ack", or the pairing secret echoed back (Clave and nsec.app echo
// it). Without a secret — a reconnect of an already-paired client — anything
// goes. Callers only log a mismatch: go-nostr accepts a response only if it is
// encrypted by the signer's own key, so the answer already came from the
// signer, and Android re-sends its secret on every reconnect.
func nip46ConnectConfirmed(result, secret string) bool {
	if secret == "" {
		return true
	}
	return result == "ack" || result == secret
}
