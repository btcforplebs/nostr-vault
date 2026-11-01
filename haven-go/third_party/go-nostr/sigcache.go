package nostr

import (
	"crypto/sha256"
	"sync"
	"sync/atomic"
)

// haven: remembers signatures that already verified, so the same note is
// checked once rather than once per relay that sends it (the pool dedupes
// after verifying) and once more when it reaches the local relay. On the
// iPhone sim that repeat work was about a third of the app's CPU while the
// feed loaded (RESEARCH sweep 2026-11-01).
//
// The key is never the event's claimed ID. It is sha256(hash || sig), where
// hash is the sha256 of the serialized event that CheckSignature computes
// itself, so a different body, pubkey or signature is a different key and
// always gets a full verify. Only successes are stored, so a cache hit can
// only ever repeat a "valid" answer that libsecp256k1/btcec already gave for
// exactly these bytes.

const sigCacheGeneration = 1 << 15 // entries per generation; two are kept

type sigCacheKey [32]byte

type sigCache struct {
	mu        sync.Mutex
	cur, prev map[sigCacheKey]struct{}
}

var verifiedSigs = &sigCache{cur: make(map[sigCacheKey]struct{}, sigCacheGeneration)}

var sigCacheHits, sigCacheMisses atomic.Uint64

func sigCacheKeyFor(hash [32]byte, sig []byte) sigCacheKey {
	h := sha256.New()
	h.Write(hash[:])
	h.Write(sig)
	var k sigCacheKey
	h.Sum(k[:0])
	return k
}

func (c *sigCache) has(k sigCacheKey) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.cur[k]; ok {
		return true
	}
	if _, ok := c.prev[k]; ok {
		// still in use: carry it into the current generation
		c.addLocked(k)
		return true
	}
	return false
}

func (c *sigCache) add(k sigCacheKey) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.addLocked(k)
}

// addLocked bounds memory with two generations: when the current one fills
// it becomes the previous one and the old previous one is dropped, so at most
// 2*sigCacheGeneration keys (32 bytes each) are held.
func (c *sigCache) addLocked(k sigCacheKey) {
	if len(c.cur) >= sigCacheGeneration {
		c.prev = c.cur
		c.cur = make(map[sigCacheKey]struct{}, sigCacheGeneration)
	}
	c.cur[k] = struct{}{}
}

// checkSignatureCached returns verify's answer for (hash, sig), calling it
// only when these exact bytes have not verified before.
func checkSignatureCached(hash [32]byte, sig []byte, verify func() bool) bool {
	k := sigCacheKeyFor(hash, sig)
	if verifiedSigs.has(k) {
		sigCacheHits.Add(1)
		return true
	}
	sigCacheMisses.Add(1)
	if !verify() {
		return false
	}
	verifiedSigs.add(k)
	return true
}

// SigCacheStats reports how many CheckSignature calls were answered from the
// cache and how many ran the full verify.
func SigCacheStats() (hits, misses uint64) {
	return sigCacheHits.Load(), sigCacheMisses.Load()
}

// ResetSigCache empties the cache and its counters. For tests.
func ResetSigCache() {
	verifiedSigs.mu.Lock()
	verifiedSigs.cur = make(map[sigCacheKey]struct{}, sigCacheGeneration)
	verifiedSigs.prev = nil
	verifiedSigs.mu.Unlock()
	sigCacheHits.Store(0)
	sigCacheMisses.Store(0)
}
