package box

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"unicode/utf8"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// Two-scan device pairing, the box's side (docs/MESH_PAIRING_CONTRACT.md).
// This file is §1, the nvpair code: what the box shows in its web UI, and
// how a code reads. It is pure, as iOS MeshPairing.swift, Android
// fips/MeshPairing.kt and web mesh-pairing.js are, and it agrees with them
// through the shared fixtures in
// HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing
// (pairing_test.go reads them). No keys here: the box's mesh key is
// nv-mesh's (pairing_dial.go asks it to open and seal hellos).

// PairNameMax is a device name's longest form, in Unicode code points.
const PairNameMax = 40

// pairRoles are the wire roles (iOS MeshDeviceRole raw values).
var pairRoles = []string{"phone", "mac", "homeVault", "browser"}

func isPairRole(r string) bool {
	for _, k := range pairRoles {
		if k == r {
			return true
		}
	}
	return false
}

// PairCode is a read nvpair code. Secret is set for A's code (`s`); Echo and
// BSecret for B's (`e`, `b`).
type PairCode struct {
	Mesh     string // npub
	MeshHex  string
	Name     string
	Role     string
	Owner    string // npub
	OwnerHex string
	Secret   string
	Echo     string
	BSecret  string
}

// PairCodeArgs builds a code (BuildPairCode). S for A's code, else E and B.
type PairCodeArgs struct {
	M, N, R, O string
	S, E, B    string
}

// BuildPairCode is `nvpair:v1?…` for this device, fields in the contract's
// order, the name trimmed and cut to PairNameMax, percent-encoded.
func BuildPairCode(a PairCodeArgs) string {
	q := []string{"m=" + a.M}
	if n := cleanPairName(a.N); n != "" {
		q = append(q, "n="+percentEncode(n))
	}
	q = append(q, "r="+a.R, "o="+a.O)
	if a.S != "" {
		q = append(q, "s="+a.S)
	} else {
		q = append(q, "e="+a.E, "b="+a.B)
	}
	return "nvpair:v1?" + strings.Join(q, "&")
}

// ParsePairCode reads a code. refusal is one of the contract's §1 names
// ("" when the code reads). ownMesh is this device's own mesh npub ("" to
// skip that check).
func ParsePairCode(uri, ownMesh string) (PairCode, string) {
	u := strings.TrimSpace(uri)
	if len(u) < 7 || !strings.EqualFold(u[:7], "nvpair:") {
		return PairCode{}, "notPairing"
	}
	rest := u[7:]
	version, query, _ := strings.Cut(rest, "?")
	if version != "v1" {
		return PairCode{}, "unsupportedVersion"
	}
	fields := map[string]string{}
	if query != "" {
		for _, part := range strings.Split(query, "&") {
			key, value, ok := strings.Cut(part, "=")
			if !ok {
				return PairCode{}, "malformed"
			}
			dec, ok := percentDecode(value)
			if !ok {
				return PairCode{}, "malformed"
			}
			if _, dup := fields[key]; dup {
				return PairCode{}, "malformed"
			}
			fields[key] = dec
		}
	}
	meshHex := npubHex(fields["m"])
	if meshHex == "" {
		return PairCode{}, "badAddress"
	}
	if !isPairRole(fields["r"]) {
		return PairCode{}, "unknownRole"
	}
	ownerHex := npubHex(fields["o"])
	if ownerHex == "" {
		return PairCode{}, "missingOwner"
	}
	s, hasS := fields["s"]
	e, hasE := fields["e"]
	b, hasB := fields["b"]
	// A's code has s and no b; B's has e and b.
	if hasS == hasE || hasS == hasB {
		return PairCode{}, "badCode"
	}
	secret := s
	if !hasS {
		secret = e
	}
	if secretBytes(secret) == nil || (hasB && secretBytes(b) == nil) {
		return PairCode{}, "badCode"
	}
	name := strings.TrimSpace(fields["n"])
	if utf8.RuneCountInString(name) > PairNameMax {
		return PairCode{}, "nameTooLong"
	}
	if ownMesh != "" && npubHex(ownMesh) == meshHex {
		return PairCode{}, "ownAddress"
	}
	p := PairCode{Mesh: mustNpub(meshHex), MeshHex: meshHex, Name: name, Role: fields["r"], Owner: mustNpub(ownerHex), OwnerHex: ownerHex}
	if hasS {
		p.Secret = s
	} else {
		p.Echo, p.BSecret = e, b
	}
	return p, ""
}

// npubHex is the 32-byte key of an npub as lower-case hex, or "". Upper or
// lower case, never mixed.
func npubHex(s string) string {
	if len(s) != 63 {
		return ""
	}
	if strings.ToLower(s) != s && strings.ToUpper(s) != s {
		return ""
	}
	prefix, v, err := nip19.Decode(strings.ToLower(s))
	if err != nil || prefix != "npub" {
		return ""
	}
	h, _ := v.(string)
	if !isHex64(h) {
		return ""
	}
	return h
}

func mustNpub(hex string) string {
	n, _ := nip19.EncodePublicKey(hex)
	return n
}

func isHex64(h string) bool {
	if len(h) != 64 {
		return false
	}
	for _, c := range h {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func isHex64AnyCase(h string) bool { return isHex64(strings.ToLower(h)) }

func hexBytes(h string) []byte {
	b, _ := hex.DecodeString(h)
	return b
}

const pairB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

// secretBytes decodes a 22-character canonical base64url secret to its 16
// bytes, or nil.
func secretBytes(s string) []byte {
	if len(s) != 22 {
		return nil
	}
	var out []byte
	bits, acc := 0, 0
	for _, c := range []byte(s) {
		i := strings.IndexByte(pairB64, c)
		if i < 0 {
			return nil
		}
		acc = (acc << 6) | i
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte((acc>>bits)&0xff))
		}
	}
	if len(out) != 16 || acc&((1<<bits)-1) != 0 {
		return nil // canonical: the spare bits are zero
	}
	return out
}

// base64url of bytes, no padding.
func base64url(b []byte) string {
	var sb strings.Builder
	acc, bits := 0, 0
	for _, c := range b {
		acc = (acc << 8) | int(c)
		bits += 8
		for bits >= 6 {
			bits -= 6
			sb.WriteByte(pairB64[(acc>>bits)&63])
		}
	}
	if bits > 0 {
		sb.WriteByte(pairB64[(acc<<(6-bits))&63])
	}
	return sb.String()
}

// cleanPairName trims a name and cuts it to PairNameMax code points.
func cleanPairName(n string) string {
	n = strings.TrimSpace(n)
	if utf8.RuneCountInString(n) <= PairNameMax {
		return n
	}
	r := []rune(n)
	return string(r[:PairNameMax])
}

func isUnreserved(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~'
}

// percentEncode writes every byte outside A-Z a-z 0-9 - . _ ~ as %XX.
func percentEncode(s string) string {
	const hexUp = "0123456789ABCDEF"
	var sb strings.Builder
	for _, c := range []byte(s) {
		if isUnreserved(c) {
			sb.WriteByte(c)
			continue
		}
		sb.WriteByte('%')
		sb.WriteByte(hexUp[c>>4])
		sb.WriteByte(hexUp[c&15])
	}
	return sb.String()
}

// percentDecode undoes percentEncode; false for a bad escape or bytes that
// are not UTF-8.
func percentDecode(s string) (string, bool) {
	var out []byte
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			out = append(out, s[i])
			continue
		}
		if i+2 >= len(s) {
			return "", false
		}
		b, err := hex.DecodeString(s[i+1 : i+3])
		if err != nil {
			return "", false
		}
		out = append(out, b[0])
		i += 2
	}
	if !utf8.Valid(out) {
		return "", false
	}
	return string(out), true
}

// newPairSecret is a fresh one-time secret: 16 random bytes, base64url.
func newPairSecret() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err) // the OS has no randomness: nothing safe can be shown
	}
	return base64url(b[:])
}
