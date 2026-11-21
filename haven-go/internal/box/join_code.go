package box

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"math/big"
	"strings"
	"sync"
	"time"
)

// One-time join codes (One Vault addendum A.3). The first account makes
// one in the web app; the new account signs in to the box with its own
// signer and types it. The code proves the first account allowed the join;
// the signature proves the new account holds its key. Both are needed.
//
// A code is good for joinCodeTTL and one use. Only its sha256 is kept, in
// memory: a restart forgets every open code. Codes are compared in constant
// time, and wrong codes are capped per client and box-wide by the same
// limiter as the claim page (ratelimit.go). The store's setup code
// (NV_SETUP_CODE) is never a join code: it only ever claims the first
// account.

const (
	joinCodeTTL     = 15 * time.Minute
	joinCodeMaxOpen = 5 // a sixth code replaces the oldest open one
	// joinCodeAlphabet has no 0/O, 1/I/L: read off one screen, typed on another.
	joinCodeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	joinCodeLen      = 12 // ~59 bits
)

var (
	ErrJoinCodeWrong   = errors.New("that code isn't right or has expired: ask the box's owner for a new one")
	ErrJoinCodeTooMany = errors.New("too many wrong codes: wait a minute, then try again")
)

type joinCode struct {
	sum     [32]byte
	expires time.Time
}

// JoinCodes makes and takes one-time join codes.
type JoinCodes struct {
	Now func() time.Time

	mu    sync.Mutex
	open  []joinCode
	limit failLimiter
}

// NewJoinCodes is an empty set of codes on the wall clock.
func NewJoinCodes() *JoinCodes { return &JoinCodes{Now: time.Now} }

func (j *JoinCodes) init() {
	if j.limit.window == 0 {
		j.limit = failLimiter{window: claimFailWindow, maxFails: claimMaxFails, maxAll: claimMaxFailsAll, maxClients: claimMaxClients}
	}
}

// normalizeJoinCode: upper case, without the dashes and spaces a person
// types or copies.
func normalizeJoinCode(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, strings.ToUpper(strings.TrimSpace(s)))
}

func (j *JoinCodes) dropExpired(now time.Time) {
	keep := j.open[:0]
	for _, c := range j.open {
		if now.Before(c.expires) {
			keep = append(keep, c)
		}
	}
	j.open = keep
}

// New makes a code, shown as XXXX-XXXX-XXXX, and when it expires.
func (j *JoinCodes) New() (string, time.Time, error) {
	var b strings.Builder
	max := big.NewInt(int64(len(joinCodeAlphabet)))
	for i := 0; i < joinCodeLen; i++ {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", time.Time{}, err
		}
		b.WriteByte(joinCodeAlphabet[n.Int64()])
	}
	code := b.String()
	j.mu.Lock()
	defer j.mu.Unlock()
	now := j.Now()
	j.dropExpired(now)
	if len(j.open) >= joinCodeMaxOpen {
		j.open = j.open[1:]
	}
	exp := now.Add(joinCodeTTL)
	j.open = append(j.open, joinCode{sum: sha256.Sum256([]byte(normalizeJoinCode(code))), expires: exp})
	return code, exp, nil
}

// Redeem takes code from client: nil and the code is spent, or an error
// (wrong or expired, or too many wrong codes). Every open code is compared,
// each in constant time.
func (j *JoinCodes) Redeem(client, code string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.init()
	now := j.Now()
	if j.limit.blocked(client, now) {
		return ErrJoinCodeTooMany
	}
	j.dropExpired(now)
	got := sha256.Sum256([]byte(normalizeJoinCode(code)))
	match := -1
	for i, c := range j.open {
		if subtle.ConstantTimeCompare(got[:], c.sum[:]) == 1 && code != "" {
			match = i
		}
	}
	if match < 0 {
		j.limit.fail(client, now)
		return ErrJoinCodeWrong
	}
	j.open = append(j.open[:match], j.open[match+1:]...)
	return nil
}
