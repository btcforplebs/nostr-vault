package nostr

import (
	"strconv"
	"strings"
	"sync"

	jsoniter "github.com/json-iterator/go"
	"golang.org/x/exp/constraints"
)

var json = jsoniter.ConfigFastest

// HAVEN PATCH: namedLock used to hash names into 50 shared mutexes, and
// EnsureRelay holds its lock across the whole dial (up to 15 s). A relay
// stuck connecting then held up every other relay that hashed into its
// bucket, so a healthy seed's connect waited the full 15 s whenever it
// collided with a dead one (the hash seed is per process, so 1 run in ~10).
// Each name now has its own mutex, freed once nobody holds or waits on it.
type nameLock struct {
	mu   sync.Mutex
	refs int
}

var (
	namedLocksMu sync.Mutex
	namedLocks   = map[string]*nameLock{}
)

func namedLock(name string) (unlock func()) {
	namedLocksMu.Lock()
	l := namedLocks[name]
	if l == nil {
		l = &nameLock{}
		namedLocks[name] = l
	}
	l.refs++
	namedLocksMu.Unlock()

	l.mu.Lock()
	return func() {
		l.mu.Unlock()
		namedLocksMu.Lock()
		if l.refs--; l.refs == 0 {
			delete(namedLocks, name)
		}
		namedLocksMu.Unlock()
	}
}

func similar[E constraints.Ordered](as, bs []E) bool {
	if len(as) != len(bs) {
		return false
	}

	for _, a := range as {
		for _, b := range bs {
			if b == a {
				goto next
			}
		}
		// didn't find a B that corresponded to the current A
		return false

	next:
		continue
	}

	return true
}

// Escaping strings for JSON encoding according to RFC8259.
// Also encloses result in quotation marks "".
func escapeString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			// quotation mark
			dst = append(dst, []byte{'\\', '"'}...)
		case c == '\\':
			// reverse solidus
			dst = append(dst, []byte{'\\', '\\'}...)
		case c >= 0x20:
			// default, rest below are control chars
			dst = append(dst, c)
		case c == 0x08:
			dst = append(dst, []byte{'\\', 'b'}...)
		case c < 0x09:
			dst = append(dst, []byte{'\\', 'u', '0', '0', '0', '0' + c}...)
		case c == 0x09:
			dst = append(dst, []byte{'\\', 't'}...)
		case c == 0x0a:
			dst = append(dst, []byte{'\\', 'n'}...)
		case c == 0x0c:
			dst = append(dst, []byte{'\\', 'f'}...)
		case c == 0x0d:
			dst = append(dst, []byte{'\\', 'r'}...)
		case c < 0x10:
			dst = append(dst, []byte{'\\', 'u', '0', '0', '0', 0x57 + c}...)
		case c < 0x1a:
			dst = append(dst, []byte{'\\', 'u', '0', '0', '1', 0x20 + c}...)
		case c < 0x20:
			dst = append(dst, []byte{'\\', 'u', '0', '0', '1', 0x47 + c}...)
		}
	}
	dst = append(dst, '"')
	return dst
}

func arePointerValuesEqual[V comparable](a *V, b *V) bool {
	if a == nil && b == nil {
		return true
	}
	if a != nil && b != nil {
		return *a == *b
	}
	return false
}

func subIdToSerial(subId string) int64 {
	n := strings.Index(subId, ":")
	if n < 0 || n > len(subId) {
		return -1
	}
	serialId, _ := strconv.ParseInt(subId[0:n], 10, 64)
	return serialId
}

func isLowerHex(thing string) bool {
	for _, charNumber := range thing {
		if (charNumber >= 48 && charNumber <= 57) || (charNumber >= 97 && charNumber <= 102) {
			continue
		}
		return false
	}
	return true
}

func extractSubID(jsonStr string) string {
	// look for "EVENT" pattern
	start := strings.Index(jsonStr, `"EVENT"`)
	if start == -1 {
		return ""
	}

	// move to the next quote
	offset := strings.Index(jsonStr[start+7:], `"`)
	if offset == -1 {
		return ""
	}

	start += 7 + offset + 1

	// find the ending quote
	end := strings.Index(jsonStr[start:], `"`)

	// get the contents
	return jsonStr[start : start+end]
}

func extractEventID(jsonStr string) string {
	// look for "id" pattern
	start := strings.Index(jsonStr, `"id"`)
	if start == -1 {
		return ""
	}

	// move to the next quote
	offset := strings.IndexRune(jsonStr[start+4:], '"')
	start += 4 + offset + 1

	// get 64 characters of the id
	return jsonStr[start : start+64]
}

func extractEventPubKey(jsonStr string) string {
	// look for "pubkey" pattern
	start := strings.Index(jsonStr, `"pubkey"`)
	if start == -1 {
		return ""
	}

	// move to the next quote
	offset := strings.IndexRune(jsonStr[start+8:], '"')
	start += 8 + offset + 1

	// get 64 characters of the pubkey
	return jsonStr[start : start+64]
}

func extractDTag(jsonStr string) string {
	// look for ["d", pattern
	start := strings.Index(jsonStr, `["d"`)
	if start == -1 {
		return ""
	}

	// move to the next quote
	offset := strings.IndexRune(jsonStr[start+4:], '"')
	start += 4 + offset + 1

	// find the ending quote
	end := strings.IndexRune(jsonStr[start:], '"')
	if end == -1 {
		return ""
	}

	// get the contents
	return jsonStr[start : start+end]
}

func extractTimestamp(jsonStr string) Timestamp {
	// look for "created_at": pattern
	start := strings.Index(jsonStr, `"created_at"`)
	if start == -1 {
		return 0
	}

	// move to the next number
	offset := strings.IndexAny(jsonStr[start+12:], "9876543210")
	if offset == -1 {
		return 0
	}
	start += 12 + offset

	// find the end
	end := strings.IndexAny(jsonStr[start:], ",} ")
	if end == -1 {
		return 0
	}

	// get the contents
	ts, _ := strconv.ParseInt(jsonStr[start:start+end], 10, 64)
	return Timestamp(ts)
}
