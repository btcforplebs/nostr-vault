package main

import (
	"encoding/json"
	"strings"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
)

// nostrConnectAck checks whether ev is a signer's answer to our nostrconnect://
// pairing request and, if so, returns the signer's pubkey.
//
// In the nostrconnect flow the client shows a URI carrying its own pubkey and
// a fresh secret; the signer (Clave, Amber, nsec.app) answers with a kind
// 24133 event, NIP-44 encrypted to us, whose `result` is that secret. Anyone
// can publish a 24133 tagged to our pubkey, so the secret is the only proof
// the answer came from the app the user approved in — "ack" is refused.
//
// Clave's opt-in multi-account form puts a JSON object in `result` with the
// secret as `echoed_secret`; that is accepted too.
func nostrConnectAck(ev *nostr.Event, clientSK, clientPK, secret string) (string, bool) {
	if ev == nil || ev.Kind != nostr.KindNostrConnect || secret == "" {
		return "", false
	}
	if !ev.Tags.ContainsAny("p", []string{clientPK}) {
		return "", false
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return "", false
	}
	key, err := nip44.GenerateConversationKey(ev.PubKey, clientSK)
	if err != nil {
		return "", false
	}
	plain, err := nip44.Decrypt(ev.Content, key)
	if err != nil {
		return "", false
	}
	var resp struct {
		Result string `json:"result"`
		Error  string `json:"error"`
	}
	if err := json.Unmarshal([]byte(plain), &resp); err != nil || resp.Error != "" {
		return "", false
	}
	echoed := resp.Result
	if strings.HasPrefix(echoed, "{") {
		var multi struct {
			EchoedSecret string `json:"echoed_secret"`
		}
		if json.Unmarshal([]byte(echoed), &multi) == nil {
			echoed = multi.EchoedSecret
		}
	}
	if echoed != secret {
		return "", false
	}
	return ev.PubKey, true
}
