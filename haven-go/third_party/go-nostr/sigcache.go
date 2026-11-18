package nostr

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
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

// SigCacheLen reports how many keys the verified set holds. For tests.
func SigCacheLen() int {
	verifiedSigs.mu.Lock()
	defer verifiedSigs.mu.Unlock()
	return len(verifiedSigs.cur) + len(verifiedSigs.prev)
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

// haven: after a restart the upstream relays send again notes this device
// already stores, and each one was verified again: about 3.6 s of CPU in the
// first 20 s on Android (RESEARCH NV_PERF_REVIEW_2026_11_18_ANDROID_WEB). The
// verified set above lives in memory only, so it starts empty each launch.
//
// storedCopy lets the read loop skip the check for an event that is, byte
// for byte, one the local store already holds. Every path that writes those
// stores verified the signature over the stored event's own serialization
// first (go-nostr's read loop, khatru's EVENT handler, the backup import's
// importable, mesh copy), or signed it itself. The match is never on the
// claimed id alone:
//   - the incoming event's serialization must hash to its claimed id;
//   - the stored copy's serialization must hash to that same value, so a
//     stored event whose claimed id was doctored (the read loop checks the
//     signature over the content, not the id) vouches for nothing else;
//   - pubkey and sig must be identical strings.
// So the signature skipped here is one already verified for exactly this
// pubkey and this hash, and it is added to the verified set above on the
// same grounds. Anything else gets the full CheckSignature.

var storedEventLookup atomic.Pointer[func(id string) *Event]

var storedCopyHits atomic.Uint64

// SetStoredEventLookup installs the local-store read storedCopy uses: the
// stored event with this id, or nil. It must only search stores whose every
// write verified the signature (never the unsigned blob index). Nil turns
// the skip off.
func SetStoredEventLookup(lookup func(id string) *Event) {
	if lookup == nil {
		storedEventLookup.Store(nil)
		return
	}
	storedEventLookup.Store(&lookup)
}

// StoredCopyHits reports how many signature checks storedCopy skipped.
func StoredCopyHits() uint64 { return storedCopyHits.Load() }

func storedCopy(evt *Event) bool {
	lookup := storedEventLookup.Load()
	if lookup == nil || len(evt.ID) != 64 || len(evt.PubKey) != 64 || len(evt.Sig) != 128 {
		return false
	}
	msg := sha256.Sum256(evt.Serialize())
	var id [32]byte
	if n, err := hex.Decode(id[:], []byte(evt.ID)); err != nil || n != 32 || id != msg {
		return false
	}
	var sig [64]byte
	if n, err := hex.Decode(sig[:], []byte(evt.Sig)); err != nil || n != 64 {
		return false
	}
	key := sigCacheKeyFor(msg, sig[:])
	if verifiedSigs.has(key) {
		// Verified already this launch (another relay's copy): CheckSignature
		// answers from memory, cheaper than reading the store.
		return false
	}
	stored := (*lookup)(evt.ID)
	if stored == nil || stored.Sig != evt.Sig || stored.PubKey != evt.PubKey {
		return false
	}
	if sha256.Sum256(stored.Serialize()) != msg {
		return false
	}
	// The same claim the verified set holds: these exact bytes verified. So
	// the other relays' copies, and the local relay's own check, are free.
	verifiedSigs.add(key)
	storedCopyHits.Add(1)
	return true
}

// haven: the verified set above starts empty each launch, so every note the
// relays send again after a restart was checked again: about 6,500 checks in
// the first 20 s on Android after the Kotlin side stopped repeating its own
// (perf round 3, 2026-11-18). SaveVerifiedSigs / LoadVerifiedSigs keep it on
// disk next to the event stores. The file holds only keys, sha256(hash ||
// sig) of events that verified, so a loaded key can only ever repeat a
// "valid" answer for exactly the same bytes; anything else misses and gets
// the full check. It trusts its folder as much as the event stores beside it
// already are (their events are served without a second check).

var verifiedSigsMagic = []byte("NVSC0001")

// SaveVerifiedSigs writes the verified set to path through a temp file, so a
// crash never leaves half a file. It returns how many keys it wrote.
func SaveVerifiedSigs(path string) (int, error) {
	verifiedSigs.mu.Lock()
	keys := make([]sigCacheKey, 0, len(verifiedSigs.cur)+len(verifiedSigs.prev))
	for k := range verifiedSigs.prev {
		if _, dup := verifiedSigs.cur[k]; !dup {
			keys = append(keys, k)
		}
	}
	for k := range verifiedSigs.cur {
		keys = append(keys, k)
	}
	verifiedSigs.mu.Unlock()

	tmp, err := os.CreateTemp(filepath.Dir(path), ".verified-sigs-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	w := bufio.NewWriter(tmp)
	w.Write(verifiedSigsMagic)
	for i := range keys {
		w.Write(keys[i][:])
	}
	if err := w.Flush(); err != nil {
		tmp.Close()
		return 0, err
	}
	if err := tmp.Close(); err != nil {
		return 0, err
	}
	return len(keys), os.Rename(tmp.Name(), path)
}

// LoadVerifiedSigs adds the keys saved at path to the verified set, as its
// older generation (a key that is used again moves into the current one). A
// missing file loads nothing; a foreign one is an error and loads nothing.
func LoadVerifiedSigs(path string) (int, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !bytes.HasPrefix(data, verifiedSigsMagic) {
		return 0, errors.New("not a verified-signatures file")
	}
	data = data[len(verifiedSigsMagic):]
	n := len(data) / len(sigCacheKey{}) // whole keys only
	verifiedSigs.mu.Lock()
	defer verifiedSigs.mu.Unlock()
	// The set stays within its two generations: keep only the newest keys
	// (the file ends with the newest) that fit beside what is held now.
	room := 2*sigCacheGeneration - len(verifiedSigs.cur) - len(verifiedSigs.prev)
	if room < 0 {
		room = 0
	}
	if n > room {
		data = data[(n-room)*len(sigCacheKey{}) : n*len(sigCacheKey{})]
		n = room
	}
	if verifiedSigs.prev == nil {
		verifiedSigs.prev = make(map[sigCacheKey]struct{}, n)
	}
	for i := 0; i < n; i++ {
		var k sigCacheKey
		copy(k[:], data[i*len(k):])
		if _, ok := verifiedSigs.cur[k]; !ok {
			verifiedSigs.prev[k] = struct{}{}
		}
	}
	return n, nil
}
