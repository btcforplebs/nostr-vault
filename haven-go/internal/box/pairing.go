package box

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// Two-scan pairing, §2, §3 and §5 of docs/MESH_PAIRING_CONTRACT.md: the
// owner and role checks, the hello and ack (the decrypted content of a kind
// 21195 event) and the digests behind the ack and the check words. Pure, as
// web mesh-pairing.js; the fixtures in pairing_test.go pin every rule.

// PairHelloKind is the ephemeral event that carries a hello or an ack.
const PairHelloKind = 21195

// The contract's §6 timings, in seconds.
const (
	pairCodeLifetime = 180
	pairScanWindow   = 180
	pairAckWindow    = 360
	pairHelloSkew    = 180
)

// PairHello is a read hello (B → A).
type PairHello struct {
	S string `json:"s"`
	N string `json:"n,omitempty"`
	R string `json:"r"`
	O string `json:"o"` // npub, re-encoded lower case
	T int64  `json:"t"`
}

// helloWire is the hello as sent, in the contract's key order.
type helloWire struct {
	V int    `json:"v"`
	S string `json:"s"`
	N string `json:"n,omitempty"`
	R string `json:"r"`
	O string `json:"o"`
	T int64  `json:"t"`
}

// PairHelloJSON is the compact hello for the given fields.
func PairHelloJSON(s, n, r, o string, t int64) string {
	b, _ := json.Marshal(helloWire{V: 1, S: s, N: cleanPairName(n), R: r, O: o, T: t})
	return string(b)
}

// PairAckJSON is the compact ack: `d` the digest, `w` when A linked with
// the check words rather than a scan.
func PairAckJSON(d string, w bool) string {
	if w {
		return `{"v":1,"ack":true,"d":"` + d + `","w":true}`
	}
	return `{"v":1,"ack":true,"d":"` + d + `"}`
}

// ParsePairHello reads a hello, or nil when the content is not one (bad
// JSON, v ≠ 1, an ack, a bad secret, role, owner or time, a name over 40).
func ParsePairHello(text string) *PairHello {
	var raw map[string]json.RawMessage
	if json.Unmarshal([]byte(text), &raw) != nil || raw == nil {
		return nil
	}
	if string(raw["v"]) != "1" {
		return nil
	}
	if _, isAck := raw["ack"]; isAck {
		return nil
	}
	var s, r, o, n string
	var t json.Number
	if json.Unmarshal(raw["s"], &s) != nil || json.Unmarshal(raw["r"], &r) != nil || json.Unmarshal(raw["o"], &o) != nil {
		return nil
	}
	if rn, ok := raw["n"]; ok && json.Unmarshal(rn, &n) != nil {
		return nil
	}
	if json.Unmarshal(raw["t"], &t) != nil {
		return nil
	}
	ti, err := t.Int64()
	if err != nil || strings.ContainsAny(t.String(), ".eE") {
		return nil
	}
	if secretBytes(s) == nil || !isPairRole(r) || npubHex(o) == "" {
		return nil
	}
	name := strings.TrimSpace(n)
	if utf8.RuneCountInString(name) > PairNameMax {
		return nil
	}
	return &PairHello{S: s, N: name, R: r, O: mustNpub(npubHex(o)), T: ti}
}

// PairAck is a read ack (A → B).
type PairAck struct {
	D string
	W bool
}

// ParsePairAck reads an ack, or nil: `ack` not true, `d` not 64 lower-case
// hex, `w` present but not a bool.
func ParsePairAck(text string) *PairAck {
	var raw map[string]json.RawMessage
	if json.Unmarshal([]byte(text), &raw) != nil || raw == nil {
		return nil
	}
	if string(raw["v"]) != "1" || string(raw["ack"]) != "true" {
		return nil
	}
	var d string
	if json.Unmarshal(raw["d"], &d) != nil || !isHex64(d) {
		return nil
	}
	a := &PairAck{D: d}
	if rw, ok := raw["w"]; ok {
		if json.Unmarshal(rw, &a.W) != nil {
			return nil
		}
	}
	return a
}

// PairOwnerCheck is §2: "ok" (the active account), "switchTo:<npub>" (another
// account here) or "otherOwner". Each is an npub.
func PairOwnerCheck(owner, active string, accounts []string) string {
	h := npubHex(owner)
	if h == "" {
		return "otherOwner"
	}
	if active != "" && npubHex(active) == h {
		return "ok"
	}
	for _, a := range accounts {
		if npubHex(a) == h {
			return "switchTo:" + a
		}
	}
	return "otherOwner"
}

// PairKnownDevice is one already-stored device for PairRoleCheck.
type PairKnownDevice struct {
	Npub string
	Role string // wire role
}

// PairRoleCheck is §2 (Tron 1): "add", "alreadyLinked" or
// "refuseOtherRole:<role>". A known device is never moved to another role.
func PairRoleCheck(npub, role string, existing []PairKnownDevice) string {
	h := npubHex(npub)
	for _, d := range existing {
		if npubHex(d.Npub) != h {
			continue
		}
		if d.Role == role {
			return "alreadyLinked"
		}
		return "refuseOtherRole:" + d.Role
	}
	return "add"
}

// PairAckDigest is the ack's proof. With bSecret: hex SHA-256(s_A ‖ s_B ‖
// m_A ‖ m_B), the scan path. Without: hex SHA-256(s_A ‖ m_A ‖ m_B), the
// Accept path (`w`). "" for bad input.
func PairAckDigest(secret, aHex, bHex, bSecret string) string {
	s := secretBytes(secret)
	if s == nil || !isHex64AnyCase(aHex) || !isHex64AnyCase(bHex) {
		return ""
	}
	var sb []byte
	if bSecret != "" {
		if sb = secretBytes(bSecret); sb == nil {
			return ""
		}
	}
	h := sha256.New()
	h.Write(s)
	h.Write(sb)
	h.Write(hexBytes(strings.ToLower(aHex)))
	h.Write(hexBytes(strings.ToLower(bHex)))
	return hex.EncodeToString(h.Sum(nil))
}

// PairCheckWordIndexes are the 4 check words (§5) as indexes into the BIP-39
// English list: the first 44 bits of SHA-256(m_A ‖ m_B ‖ s_A), 11 bits each.
// The box UI turns them into words with the list the web app already has
// (mesh-pairing-words.js), so havend carries no word list. nil for bad input.
func PairCheckWordIndexes(aHex, bHex, secret string) []int {
	s := secretBytes(secret)
	if s == nil || !isHex64AnyCase(aHex) || !isHex64AnyCase(bHex) {
		return nil
	}
	h := sha256.New()
	h.Write(hexBytes(strings.ToLower(aHex)))
	h.Write(hexBytes(strings.ToLower(bHex)))
	h.Write(s)
	sum := h.Sum(nil)
	var n uint64
	for _, b := range sum[:6] {
		n = n<<8 | uint64(b)
	}
	n >>= 4
	out := make([]int, 4)
	for i := range out {
		out[i] = int((n >> (11 * uint(3-i))) & 2047)
	}
	return out
}

// PairRoleConfirmText is §7's role confirm, read before anything is stored.
func PairRoleConfirmText(role, name string) string {
	n := strings.TrimSpace(name)
	if n == "" {
		n = "this device"
	}
	switch role {
	case "mac":
		return "Add " + n + " as your Mac: your vault syncs to it and it keeps a full copy."
	case "homeVault":
		return "Add " + n + " as your mobile vault: your new posts and media are sent to it."
	case "browser":
		return "Add " + n + " as your browser vault: it gets your new notes while it's open."
	case "phone":
		return "Add " + n + " as another of your phones."
	}
	return ""
}

// PairShortAddress is "npub1abc…wxyz", as the apps show it.
func PairShortAddress(npub string) string {
	if len(npub) <= 12 {
		return npub
	}
	return npub[:8] + "…" + npub[len(npub)-4:]
}
