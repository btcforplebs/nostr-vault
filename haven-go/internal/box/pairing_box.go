package box

import (
	"context"
	"errors"
	"log"
	"strings"
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
	byHex   string // the same, hex: only this caller may read, confirm or cancel the run
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
	// linked, expired, aborted; busy when another account's pairing is
	// live (nothing of it is shown).
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

// ErrNotYours: another signed-in account started the pairing that is
// running (Tron #2502 must-fix: the live code and secret, the confirm and
// the cancel are the starter's alone).
var ErrNotYours = errors.New("another account on this box is pairing a device right now; try again when it is done")

// ErrNoAck: the device was stored but no finder relay took the ack, so the
// phone will not hear back.
var ErrNoAck = errors.New("no relay took the answer to the phone; remove the device and pair again")

func (p *Pairing) now() int64 {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now().Unix()
}

// Start shows a fresh code for the account byHex (the signed-in caller).
// While another account's pairing is live (code shown or a device waiting),
// it is refused: a Start would otherwise cancel that run.
func (p *Pairing) Start(ctx context.Context, byHex string) (PairStatus, error) {
	npub, boxHex, ok := p.Mesh.Read()
	if !ok {
		return PairStatus{}, ErrNoMesh
	}
	byHex = strings.ToLower(byHex)
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
		code:    BuildPairCode(PairCodeArgs{M: npub, N: name, R: "mac", O: byNpub, S: secret}),
		by:      byNpub,
		byHex:   byHex,
		started: now,
		seen:    map[string]bool{},
	}
	lctx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	run.cancel = cancel
	// The check for another account's live run and the swap happen under
	// one lock, so two Starts cannot both pass the check (Tron #2502).
	p.mu.Lock()
	if old := p.run; old != nil && old.byHex != byHex && p.live(old) {
		p.mu.Unlock()
		cancel()
		return PairStatus{State: "busy"}, ErrNotYours
	}
	if p.run != nil && p.run.cancel != nil {
		p.run.cancel()
	}
	p.run = run
	p.mu.Unlock()
	if p.Relays != nil {
		go p.listen(lctx, run, boxHex, now-30)
	}
	return p.Status(byHex), nil
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

// live: the run still shows a code or waits for a confirm.
func (p *Pairing) live(r *pairRun) bool {
	if r.linked {
		return false
	}
	st := r.session.State()
	return (st == "waiting" || st == "camera") && !r.session.Expired(p.now())
}

// mine: the run a caller may act on, or ErrNotYours / ErrNotReady.
func (p *Pairing) mine(callerHex string) (*pairRun, error) {
	r := p.run
	if r == nil {
		return nil, ErrNotReady
	}
	if r.byHex != strings.ToLower(callerHex) {
		return nil, ErrNotYours
	}
	return r, nil
}

// Hello feeds one relay event to run's session. "stop" when the run is
// over (aborted, expired), else the session's outcome word. A device the
// box already pairs under another role is refused here, at the hello, so
// the owner is told before the code is spent (contract §2, Tron 1).
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
	if h := ParsePairHello(content); h != nil && p.Paired != nil && run.session.State() == "waiting" {
		known, _ := p.Paired.List()
		existing := make([]PairKnownDevice, 0, len(known))
		for _, k := range known {
			if k.Role != "" {
				existing = append(existing, PairKnownDevice{Npub: k.Npub, Role: k.Role})
			}
		}
		if rc := PairRoleCheck(mustNpub(sender), h.R, existing); strings.HasPrefix(rc, "refuseOtherRole:") {
			run.refusal = "refuseOtherRole"
			return "refuse:refuseOtherRole"
		}
	}
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
// the device, then sends the ack. Only the account that started the run
// may confirm it.
func (p *Pairing) Confirm(ctx context.Context, callerHex, role string) (PairStatus, error) {
	p.mu.Lock()
	run, err := p.mine(callerHex)
	if err != nil {
		p.mu.Unlock()
		return p.Status(callerHex), err
	}
	if run.session.Sender() == "" || run.linked {
		p.mu.Unlock()
		return p.Status(callerHex), ErrNotReady
	}
	now := p.now()
	if run.session.State() == "camera" && run.session.hello.R != role {
		p.mu.Unlock()
		return p.Status(callerHex), ErrRoleMismatch
	}
	out := run.session.AcceptWithoutScan(now)
	if out != "confirm" {
		p.mu.Unlock()
		return p.Status(callerHex), ErrNotReady
	}
	dev := *run.session.Device
	ack := run.session.Ack()
	p.mu.Unlock()

	// Seal first: a box whose mesh is away stores nothing (the phone would
	// never hear back and the code is spent either way).
	sealed, err := p.Crypto.PairAck(ctx, dev.Npub, ack)
	if err != nil {
		p.setErr(run, pairErr(err))
		return p.Status(callerHex), err
	}
	if p.Paired != nil {
		if err := p.Paired.Add(PairedDevice{Npub: dev.Npub, Name: dev.Name, Role: dev.Role, PairedAt: now, By: run.by}); err != nil {
			p.setErr(run, err.Error())
			return p.Status(callerHex), err
		}
	}
	took := 0
	if p.Relays != nil {
		took = p.Relays.Publish(ctx, sealed)
	}
	p.mu.Lock()
	run.linked, run.acked = true, took
	if took == 0 {
		run.err = ErrNoAck.Error()
	}
	p.mu.Unlock()
	if run.cancel != nil {
		run.cancel()
	}
	log.Printf("box: paired %s (%s) by two-scan pairing; ack taken by %d relays", dev.Role, PairShortAddress(dev.Npub), took)
	if took == 0 {
		return p.Status(callerHex), ErrNoAck
	}
	return p.Status(callerHex), nil
}

func (p *Pairing) setErr(run *pairRun, msg string) {
	p.mu.Lock()
	run.err = msg
	p.mu.Unlock()
}

// Cancel ends the caller's pairing; nothing is stored. Another account's
// run is left alone (ErrNotYours).
func (p *Pairing) Cancel(callerHex string) (PairStatus, error) {
	p.mu.Lock()
	run, err := p.mine(callerHex)
	if errors.Is(err, ErrNotYours) {
		p.mu.Unlock()
		return p.Status(callerHex), err
	}
	p.run = nil
	p.mu.Unlock()
	if run != nil && run.cancel != nil {
		run.cancel()
	}
	return p.Status(callerHex), nil
}

// Status is the caller's pairing as the UI shows it. Another account's live
// run reads as "busy" with nothing of it shown: no code, no secret, no
// device.
func (p *Pairing) Status(callerHex string) PairStatus {
	var st PairStatus
	st.Box.Npub, _, _ = p.Mesh.Read()
	p.mu.Lock()
	defer p.mu.Unlock()
	run := p.run
	if run == nil {
		st.State = "idle"
		return st
	}
	if run.byHex != strings.ToLower(callerHex) {
		if p.live(run) {
			st.State = "busy"
		} else {
			st.State = "idle"
		}
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
