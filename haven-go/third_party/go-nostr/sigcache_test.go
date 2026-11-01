package nostr

import "testing"

// The cache holds at most two generations, and a key still in use survives a
// rotation by moving into the current one.
func TestSigCacheGenerationsBoundMemory(t *testing.T) {
	c := &sigCache{cur: make(map[sigCacheKey]struct{})}
	key := func(i int) sigCacheKey {
		var k sigCacheKey
		k[0], k[1], k[2] = byte(i), byte(i>>8), byte(i>>16)
		return k
	}

	c.add(key(0))
	for i := 1; i < sigCacheGeneration; i++ {
		c.add(key(i))
	}
	c.add(key(sigCacheGeneration)) // rotates: 0..gen-1 become prev
	if !c.has(key(0)) {
		t.Fatal("key 0 should survive one rotation")
	}
	for i := sigCacheGeneration + 1; i < 3*sigCacheGeneration; i++ {
		c.add(key(i))
	}
	if c.has(key(1)) {
		t.Fatal("an unused key should be gone after two rotations")
	}
	if n := len(c.cur) + len(c.prev); n > 2*sigCacheGeneration {
		t.Fatalf("holding %d keys, cap is %d", n, 2*sigCacheGeneration)
	}
}
