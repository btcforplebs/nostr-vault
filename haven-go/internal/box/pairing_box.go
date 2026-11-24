package box

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Pairing is the box's two-scan pairing (Desktop Vaults plan §2.3, Tron N1,
// N4): the box is side A. The owner, signed in to the box web UI, asks for a
// code (Start); the UI shows it as a QR; the phone scans it and sends its
// hello to the finder relays; the box opens the hello (PairCrypto, nv-mesh
// holds the key), the UI shows the 4 check words, the device's name and the
// role confirm; the owner taps "They match" and Add (Confirm, one call that
// carries the role shown); the box stores the device in its paired set and
// sends the check-words ack. A box has no camera, so the ack always carries
// `w` and the phone needs its own tap too (contract §3, §5).
//
// Nothing here touches an account key, and nothing is published but the
// ack, signed by the box's mesh key. One pairing runs at a time: a new
// Start cancels the old one.
type Pairing struct {
	Mesh   MeshID
	Crypto PairCrypto
	Relays PairRelays
	Paired *PairedSet
	// Accounts: every account whose devices may pair (hex): the box's
	// counted accounts (Devices.counted). The caller's own account is the
	// active one; a hello for another counted account is "switchTo".
	Accounts func() []string
	// Name is what the code calls the box; "Nostr Vault box" when empty.
	Name string
	// Now is the clock (unix s); time.Now when nil.
	Now func() int64

	mu  sync.Mutex
	run *pairRun
}

type pairRun struct {
	session *PairingSession
	code    string
	by      string // the account that started it (npub)
	started int64
	cancel  context.CancelFunc
	seen    map[string]bool
	// outcome of the last hello that did not open the session: a
	// "refuse:<why>" or "abort", for the UI
	refusal string
	// linked: the device was stored and the ack sent
	linked bool
	acked  int // relays that took the ack
	err    string
}

// PairStatus is GET /api/box/pair.
type PairStatus struct {
	// State: idle, waiting (code shown), hello (device found: confirm),
	// linked, expired, aborted.
	State string `json:"state"`
	Code  string `json:"code,omitempty"`
	Box   struct {
		Npub string `json:"npub"`
	} `json:"box"`
	// StartedAt is when the code was shown; ExpiresAt when this step runs
	// out (the code's life while waiting, the confirm window after a hello).
	StartedAt int64 `json:"startedAt,omitempty"`
	ExpiresAt int64 `json:"expiresAt,omitempty"`
	// Device, Words (4 BIP-39 indexes) and ConfirmText come with a hello.
	Device      *PairDevice `json:"device,omitempty"`
	Words       []int       `json:"words,omitempty"`
	ConfirmText string      `json:"confirmText,omitempty"`
	// Refusal is the last hello's refusal word (otherOwner, switchTo…) or
	// "abort"; the UI has the wording.
	Refusal string `json:"refusal,omitempty"`
	Acked   int    `json:"acked,omitempty"`
	Error   string `json:"error,omitempty"`
}

// ErrNoMesh: nv-mesh has not made the box's key yet.
var ErrNoMesh = errors.New("the box's mesh is starting; try again in a moment")

// ErrNotReady: Confirm before a hello, or after the pairing ended.
var ErrNotReady = errors.New("no device is waiting to be added")

// ErrRoleMismatch: Confirm named another role than the hello's.
var ErrRoleMismatch = errors.New("the device's role changed; read the code again")

func (p *Pairing) now() int64 {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now().Unix()
}

// Start shows a fresh code for the account byHex (the signed-in caller).
func (p *Pairing) Start(ctx context.Context, byHex string) (PairStatus, error) {
	npub, boxHex, ok := p.Mesh.Read()
	if !ok {
		return PairStatus{}, ErrNoMesh
	}
	byNpub := mustNpub(byHex)
	var accounts []string
	if p.Accounts != nil {
		for _, a := range p.Accounts() {
			accounts = append(accounts, mustNpub(a))
		}
	}
	now := p.now()
	secret := newPairSecret()
	name := p.Name
	if name == "" {
		name = "Nostr Vault box"
	}
	run := &pairRun{
		session: NewPairingSession(secret, now, boxHex, byNpub, accounts),
		code:    BuildPairCode(PairCodeArgs{M: npub, N: name, R: "homeVault", O: byNpub, S: secret}),
		by:      byNpub,
		started: now,
		seen:    map[string]bool{},
	}
	lctx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	run.cancel = cancel
	p.mu.Lock()
	if p.run != nil && p.run.cancel != nil {
		p.run.cancel()
	}
	p.run = run
	p.mu.Unlock()
	if p.Relays != nil {
		go p.listen(lctx, run, boxHex, now-30)
	}
	return p.Status(), nil
}

// listen follows the finder relays for this run's hellos until it ends.
func (p *Pairing) listen(ctx context.Context, run *pairRun, boxHex string, since int64) {
	defer run.cancel()
	// The whole run is bounded: a code lives 180 s, then a hello has 180 s.
	ctx, cancel := context.WithTimeout(ctx, time.Duration(pairCodeLifetime+pairScanWindow+30)*time.Second)
	defer cancel()
	p.Relays.Listen(ctx, boxHex, since, func(ev *nostr.Event) {
		if p.Hello(ctx, run, ev) == "stop" {
			cancel()
		}
	})
}

// Hello feeds one relay event to run's session. "stop" when the run is
// over (aborted, expired), else the session's outcome word.
func (p *Pairing) Hello(ctx context.Context, run *pairRun, ev *nostr.Event) string {
	if ev == nil || ev.Kind != PairHelloKind || p.Crypto == nil {
		return "ignore:notHello"
	}
	p.mu.Lock()
	if run.seen[ev.ID] || run.linked {
		p.mu.Unlock()
		return "ignoreDuplicate"
	}
	run.seen[ev.ID] = true
	p.mu.Unlock()
	octx, cancel := context.WithTimeout(ctx, 20*time.Second)
	sender, content, err := p.Crypto.PairOpen(octx, ev)
	cancel()
	if err != nil {
		return "ignore:notHello" // not to us, bad signature, or nv-mesh is away
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	out := run.session.ReceiveHello(sender, content, p.now())
	switch {
	case out == "abort":
		run.refusal = "abort"
		return "stop"
	case out == "expired":
		return "stop"
	case len(out) > 7 && out[:7] == "refuse:":
		run.refusal = out[7:]
	}
	return out
}

// Confirm is the owner's "They match" and Add in one: role is the role the
// UI showed, so a confirm never adds a device as something else. It stores
// the device, then sends the ack.
func (p *Pairing) Confirm(ctx context.Context, role string) (PairStatus, error) {
	p.mu.Lock()
	run := p.run
	if run == nil || run.session.Sender() == "" || run.linked {
		p.mu.Unlock()
		return p.Status(), ErrNotReady
	}
	now := p.now()
	if run.session.State() == "camera" && run.session.hello.R != role {
		p.mu.Unlock()
		return p.Status(), ErrRoleMismatch
	}
	out := run.session.AcceptWithoutScan(now)
	if out != "confirm" {
		p.mu.Unlock()
		return p.Status(), ErrNotReady
	}
	dev := *run.session.Device
	ack := run.session.Ack()
	p.mu.Unlock()

	// Seal first: a box whose mesh is away stores nothing (the phone would
	// never hear back and the code is spent either way).
	sealed, err := p.Crypto.PairAck(ctx, dev.Npub, ack)
	if err != nil {
		p.setErr(run, pairErr(err))
		return p.Status(), err
	}
	if p.Paired != nil {
		if err := p.Paired.Add(PairedDevice{Npub: dev.Npub, Name: dev.Name, Role: dev.Role, PairedAt: now, By: run.by}); err != nil {
			p.setErr(run, err.Error())
			return p.Status(), err
		}
	}
	took := 0
	if p.Relays != nil {
		took = p.Relays.Publish(ctx, sealed)
	}
	p.mu.Lock()
	run.linked, run.acked = true, took
	p.mu.Unlock()
	if run.cancel != nil {
		run.cancel()
	}
	log.Printf("box: paired %s (%s) by two-scan pairing; ack taken by %d relays", dev.Role, PairShortAddress(dev.Npub), took)
	return p.Status(), nil
}

func (p *Pairing) setErr(run *pairRun, msg string) {
	p.mu.Lock()
	run.err = msg
	p.mu.Unlock()
}

// Cancel ends the current pairing; nothing is stored.
func (p *Pairing) Cancel() PairStatus {
	p.mu.Lock()
	run := p.run
	p.run = nil
	p.mu.Unlock()
	if run != nil && run.cancel != nil {
		run.cancel()
	}
	return p.Status()
}

// Status is the current pairing as the UI shows it.
func (p *Pairing) Status() PairStatus {
	var st PairStatus
	st.Box.Npub, _, _ = p.Mesh.Read()
	p.mu.Lock()
	defer p.mu.Unlock()
	run := p.run
	if run == nil {
		st.State = "idle"
		return st
	}
	now := p.now()
	s := run.session
	st.StartedAt, st.Refusal, st.Acked, st.Error = run.started, run.refusal, run.acked, run.err
	switch {
	case run.linked:
		st.State = "linked"
		st.Device = s.Device
	case s.State() == "aborted":
		st.State = "aborted"
	case s.State() == "expired" || s.State() == "done" || s.Expired(now):
		st.State = "expired"
	case s.State() == "camera":
		st.State = "hello"
		st.Device = &PairDevice{Npub: mustNpub(s.Sender()), Name: s.hello.N, Role: s.hello.R}
		st.Words = PairCheckWordIndexes(s.OwnMesh, s.Sender(), s.Secret)
		st.ConfirmText = PairRoleConfirmText(s.hello.R, s.hello.N)
		st.ExpiresAt = s.helloAt + pairScanWindow
	default:
		st.State = "waiting"
		st.Code = run.code
		st.ExpiresAt = s.CreatedAt + pairCodeLifetime
	}
	return st
}
