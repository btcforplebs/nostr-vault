//go:build !(js && wasm)

package main

// Rank only (Logen, 2026-11-25, rides 3.3.0): a paired phone gets its
// Haven's trust rank (hops 3-5) right away, with no first copy. Until now
// the rank rode the copy token, which only a first copy hands out.
//
// POST /copy/v2/rank-start takes the same proof as the start
// (copyv2_server.go checkStart): a kind 27235 signed by a paired device's
// own mesh key, p naming this vault, never the account key. Its u must name
// the rank path, so a rank proof never starts a copy and a copy proof never
// gets a rank token. It answers a token scoped to the rank: it reads
// /copy/v2/sync/trust and nothing else, builds no copy, and never drops the
// device's copy token (a copy or catch-up may be using it). Remove device
// drops it with the rest (dropDevice).
//
// B keeps it in copy_peers.json under <peer>#rank, apart from the copy
// token, so a rank pull never makes A a device this one "copied from"
// (copyHeldPeers) and the copy catch-up stays as it was. A's rank nudge
// reaches a device that holds only a rank token (copyv2_nudge.go).

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/nbd-wtf/go-nostr/nip19"
)

const (
	copyRankStartPath = "/copy/v2/rank-start"
	// copyScopeRank: a token that reads the trust rank only.
	copyScopeRank = "rank"
	// copyRankMark: copy_peers.json key suffix for B's rank-only token.
	copyRankMark = "#rank"
	// copyRankPulledMarker ends a rank pull:
	// `RANK_PULLED peer=<npub> got=<n>[ error=<code>]`.
	copyRankPulledMarker = "RANK_PULLED"
)

// startRank is POST /copy/v2/rank-start.
func (s *copyServer) startRank(w http.ResponseWriter, r *http.Request) {
	code, why, device := s.checkStart(r, copyRankStartPath)
	if code != 0 {
		http.Error(w, why, code)
		return
	}
	token := copyRandomHex(32)
	s.mu.Lock()
	s.loadTokens()
	now := s.now()
	kept := s.tokens[:0]
	for _, t := range s.tokens {
		if t.Device == device && t.Scope == copyScopeRank {
			continue // one rank token per device
		}
		if now.Sub(time.Unix(t.LastUsed, 0)) <= copyTokenIdle && t.Owner == config.OwnerPubKey && t.Device != "" {
			kept = append(kept, t)
		}
	}
	s.tokens = append(kept, copyToken{Hash: copyHashToken(token), Owner: config.OwnerPubKey, Device: device,
		Scope: copyScopeRank, Created: now.Unix(), LastUsed: now.Unix()})
	s.saveTokens()
	s.mu.Unlock()
	copyJSON(w, http.StatusOK, map[string]string{"token": token, "state": copyScopeRank})
}

// rankOnlyBearer: the request's bearer is a rank-only token. Such a token
// may read sync/trust and nothing else.
func (s *copyServer) rankOnlyBearer(r *http.Request) bool {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	h := copyHashToken(strings.TrimSpace(raw))
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loadTokens()
	for _, t := range s.tokens {
		if t.Hash == h {
			return t.Scope == copyScopeRank
		}
	}
	return false
}

// copyRankHolds: whether this device holds a rank-only token from the mesh
// key peer (hex), with the npub the app names it by.
func copyRankHolds(peer string) (string, bool) {
	npub, err := nip19.EncodePublicKey(peer)
	if err != nil {
		return "", false
	}
	for _, name := range []string{npub, peer} {
		if copyPeerToken(name+copyRankMark) != "" {
			return npub, true
		}
	}
	return "", false
}

// startRank asks A for a rank-only token with this device's signed proof
// (base64 kind 27235 for POST <base>/copy/v2/rank-start).
func (c *copyClient) startRank(ctx context.Context, startAuth string) error {
	c.token = ""
	resp, err := c.do(ctx, http.MethodPost, copyRankStartPath, map[string]string{"Authorization": "Nostr " + startAuth}, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return statusError(resp.StatusCode)
	}
	var out struct{ Token string }
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out); err != nil || !copyIsHex(out.Token, 64) {
		return copyErr("bad_manifest")
	}
	c.token = out.Token
	saveCopyPeerToken(c.peer+copyRankMark, out.Token)
	return nil
}

// rankPull brings A's trust rank over with no copy: the copy token when
// this device holds one, else the rank token, else (or when A refuses
// both) a new rank token on startAuth. Returns how many accounts got a new
// copy. A device that ranks for itself asks nothing.
func (c *copyClient) rankPull(ctx context.Context, startAuth string) (int, error) {
	if !trustRankTakesCopy() {
		return 0, nil
	}
	for _, token := range []string{copyPeerToken(c.peer), copyPeerToken(c.peer + copyRankMark)} {
		if token == "" {
			continue
		}
		c.token = token
		got := c.syncTrust(ctx)
		if !c.trustRefused {
			return got, c.trustErr
		}
	}
	if startAuth == "" {
		return 0, copyErr("auth_refused")
	}
	if err := c.startRank(ctx, startAuth); err != nil {
		return 0, err
	}
	got := c.syncTrust(ctx)
	if c.trustRefused {
		return got, copyErr("auth_refused")
	}
	return got, c.trustErr
}

// startRankPull is RankPullC: one rank pull from peer through base, in the
// copy runner (one copy, catch-up or pull at a time), ended by a
// RANK_PULLED line.
func startRankPull(ctx context.Context, spawn func(string, func()), peer, base, startAuth string) int {
	return copyRuns.begin(ctx, spawn, "copyv2.rank", func(cctx context.Context) {
		got, err := newCopyClient(peer, base).rankPull(cctx, startAuth)
		line := copyRankPulledMarker + " peer=" + peer + " got=" + strconv.Itoa(got)
		if err != nil {
			line += " error=" + copyErrorCode(err)
		}
		log.Print(line)
	})
}
