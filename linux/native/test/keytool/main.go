// Throwaway keys for the Linux package test: never a real account's.
//   keytool gen                      -> "<skhex> <npub> <pkhex>"
//   keytool auth <skhex> <METHOD> <url> [body]  -> Authorization header value (NIP-98)
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func main() {
	switch os.Args[1] {
	case "gen":
		sk := nostr.GeneratePrivateKey()
		pk, _ := nostr.GetPublicKey(sk)
		np, _ := nip19.EncodePublicKey(pk)
		fmt.Println(sk, np, pk)
	case "auth":
		sk, method, u := os.Args[2], os.Args[3], os.Args[4]
		ev := nostr.Event{Kind: 27235, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"u", u}, {"method", method}}}
		if len(os.Args) > 5 {
			s := sha256.Sum256([]byte(os.Args[5]))
			ev.Tags = append(ev.Tags, nostr.Tag{"payload", hex.EncodeToString(s[:])})
		}
		if err := ev.Sign(sk); err != nil {
			panic(err)
		}
		b, _ := json.Marshal(ev)
		fmt.Println("Nostr " + base64.StdEncoding.EncodeToString(b))
	}
}
