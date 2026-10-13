package main

import (
	"context"
	"sync"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip46"
)

// One live session per signer, so switching between accounts that each sign
// with their own bunker is instant: the session for the account switched to
// is still connected, and nothing has to log in again. Only one session is
// active (the one requests go to); the others stay connected in the
// background. nip46Mu guards the map and the active key only; it is never
// held across a network round trip, so a slow login cannot block signing
// on another session or freeze the caller.
type nip46Session struct {
	ctx        context.Context
	cancel     context.CancelFunc
	pool       *nostr.SimplePool
	client     *nip46.BunkerClient
	userPubkey string
	// What signReplyRecovery needs to read the signer's replies itself.
	signer   string
	relays   []string
	clientSK string
}

var (
	nip46Sessions = map[string]*nip46Session{} // keyed by signer (bunker) pubkey
	nip46Active   string
	// Bumped on every activation, so a login that finishes after the user
	// moved to another account is kept but does not take over.
	nip46ActiveGen uint64
	nip46Mu        sync.RWMutex
)

// nip46ClaimLogin prepares the session table for a login to `target`.
//
// A foreground login (the account switched to) drops any old session for
// that signer and claims the active slot; the generation returned tells
// nip46StoreSession whether the user is still on this signer when the login
// finishes. A background login (the owner's signer while another account is
// active) touches neither the active slot nor the generation: a live session
// for that signer already is returned as `live` and nothing changes; a dead
// one is dropped so the caller logs in again.
func nip46ClaimLogin(target string, background bool) (live *nip46Session, gen uint64) {
	nip46Mu.Lock()
	defer nip46Mu.Unlock()
	if old := nip46Sessions[target]; old != nil {
		if background && old.ctx.Err() == nil {
			return old, nip46ActiveGen
		}
		old.cancel()
		delete(nip46Sessions, target)
	}
	if !background {
		nip46Active = target
		nip46ActiveGen++
	}
	return nil, nip46ActiveGen
}

// nip46StoreSession files a finished login under `target`, closing a session
// for the same signer that finished first. Reports whether `s` is now the
// active session: only a foreground login whose generation nobody has
// moved past since nip46ClaimLogin; a background login never is.
func nip46StoreSession(target string, s *nip46Session, gen uint64) bool {
	nip46Mu.Lock()
	defer nip46Mu.Unlock()
	if old := nip46Sessions[target]; old != nil && old != s {
		old.cancel()
	}
	nip46Sessions[target] = s
	return nip46Active == target && nip46ActiveGen == gen
}
