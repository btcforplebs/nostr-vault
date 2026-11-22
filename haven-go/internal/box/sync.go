package box

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"sync"
	"time"
)

// Syncer is the box catching up from the owner's other vaults (One Vault
// spec E3): every Every, and when asked (Sync now), it catches up with each
// paired device it holds a copy token from, one at a time. A device it has
// never copied from needs a first copy, which someone starts (First): it
// builds that vault's whole copy, so the box never starts one by itself.
//
// The box reaches each vault through nv-mesh (Dial) and starts a first copy
// with a proof nv-mesh signs with the box's own mesh key, never an account
// key; so who asked does not matter, and the state is per device. The copy
// and catch-up run in the engine (Engine), which keeps every account the
// vault carries, as on a Mac.
type Syncer struct {
	Devices func() ([]string, error) // the paired devices' npubs, nv-mesh's list
	Dial    interface {
		Dial(ctx context.Context, npub string) (string, error)
		SignCopyStart(ctx context.Context, npub, base string) (string, error)
	}
	Engine interface {
		First(ctx context.Context, peer, base, auth string) error
		Sync(ctx context.Context, peer, base string) error
		State(ctx context.Context, peers []string) (CopyState, error)
	}
	Every     time.Duration // between rounds; 15 min when 0
	FirstWait time.Duration // before the first round; 1 min when 0
	Poll      time.Duration // how often a run is checked on; 2 s when 0
	RunLimit  time.Duration // longest wait on one device's run; 6 h when 0
	// NowEvery: Sync now for one device (or all) at most this often; 1 min
	// when 0 (routes_sync.go allowNow).
	NowEvery time.Duration

	mu        sync.Mutex
	kick      chan string // a device's npub, or "" for all
	lastRound time.Time
	nextRound time.Time
	round     bool // a round is running
	dialErr   map[string]string
	lastNow   map[string]time.Time // Sync now asked, by device ("" = all)
}

// ErrNotPaired: the device is not one of the owner's devices on this box's mesh.
var ErrNotPaired = errors.New("not one of the owner's devices on this box's mesh")

// ErrHasCopy: the box already holds a copy token from that device, so it
// catches up (Sync now) instead of building a whole new copy.
var ErrHasCopy = errors.New("this box already has a copy from that device: use Sync now")

func (s *Syncer) init() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.kick == nil {
		s.kick = make(chan string, 1)
		s.dialErr = map[string]string{}
	}
}

func orDur(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// Run does a round every Every, and one when kicked, until ctx ends.
func (s *Syncer) Run(ctx context.Context) {
	s.init()
	wait := orDur(s.FirstWait, time.Minute)
	for {
		s.mu.Lock()
		s.nextRound = time.Now().Add(wait)
		s.mu.Unlock()
		t := time.NewTimer(wait)
		only := ""
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		case only = <-s.kick:
			t.Stop()
		}
		s.Round(ctx, only)
		wait = orDur(s.Every, 15*time.Minute)
	}
}

// Now asks for a round now: one device (npub) or all (""). It never blocks;
// a round already asked for and not yet started takes this one's place.
func (s *Syncer) Now(device string) error {
	s.init()
	if device != "" {
		ok, err := s.paired(device)
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotPaired
		}
	}
	select {
	case s.kick <- device:
	default:
		// One is pending: make it cover everything.
		select {
		case <-s.kick:
		default:
		}
		select {
		case s.kick <- "":
		default:
		}
	}
	return nil
}

func (s *Syncer) paired(device string) (bool, error) {
	list, err := s.Devices()
	if err != nil {
		return false, err
	}
	return slices.Contains(list, device), nil
}

// Round catches up with every paired device the box holds a token from
// (only: just that one), one at a time.
func (s *Syncer) Round(ctx context.Context, only string) {
	s.init()
	s.mu.Lock()
	if s.round {
		s.mu.Unlock()
		return
	}
	s.round = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.round = false
		s.lastRound = time.Now()
		s.mu.Unlock()
	}()
	devices, err := s.Devices()
	if err != nil {
		log.Printf("box sync: devices: %v", err)
		return
	}
	if only != "" {
		devices = slices.DeleteFunc(devices, func(d string) bool { return d != only })
	}
	if len(devices) == 0 {
		return
	}
	st, err := s.Engine.State(ctx, devices)
	if err != nil {
		log.Printf("box sync: %v", err)
		return
	}
	for _, d := range st.Devices {
		if !d.Token {
			continue // a first copy brings the token
		}
		if err := s.waitIdle(ctx); err != nil {
			return
		}
		base, err := s.Dial.Dial(ctx, d.Peer)
		s.noteDial(d.Peer, err)
		if err != nil {
			log.Printf("box sync: %s: %v", shortNpub(d.Peer), err)
			continue
		}
		if err := s.Engine.Sync(ctx, d.Peer, base); err != nil {
			log.Printf("box sync: %s: %v", shortNpub(d.Peer), err)
			continue
		}
		if err := s.waitIdle(ctx); err != nil {
			return
		}
	}
}

// First starts a first copy from device: reach it, have nv-mesh sign the
// start, hand both to the engine. Returns at once; the state follows it.
func (s *Syncer) First(ctx context.Context, device string) error {
	s.init()
	ok, err := s.paired(device)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotPaired
	}
	st, err := s.Engine.State(ctx, []string{device})
	if err != nil {
		return err
	}
	if st.Busy {
		return ErrCopyBusy
	}
	// Each first copy makes that vault drop its old token and zip its whole
	// vault (Tron #2385 M1), so one is started only while the box holds no
	// working token: none yet, or the vault refused the one it has.
	for _, d := range st.Devices {
		if d.Peer == device && d.Token && !tokenRefused(d) {
			return ErrHasCopy
		}
	}
	base, err := s.Dial.Dial(ctx, device)
	s.noteDial(device, err)
	if err != nil {
		return err
	}
	auth, err := s.Dial.SignCopyStart(ctx, device, base)
	if err != nil {
		return err
	}
	return s.Engine.First(ctx, device, base, auth)
}

// tokenRefused: the last run from d failed because d no longer takes the
// box's token, so only a new first copy can bring one.
func tokenRefused(d CopyDevice) bool {
	return d.Last != nil && d.Last.Error == "auth_refused" // the engine stores the bare code (copyv2_box.go end)
}

// waitIdle waits until the engine runs no copy (RunLimit at most).
func (s *Syncer) waitIdle(ctx context.Context) error {
	deadline := time.Now().Add(orDur(s.RunLimit, 6*time.Hour))
	for {
		st, err := s.Engine.State(ctx, nil)
		if err == nil && !st.Busy {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("a copy is still running")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(orDur(s.Poll, 2*time.Second)):
		}
	}
}

func (s *Syncer) noteDial(peer string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		s.dialErr[peer] = err.Error()
	} else {
		delete(s.dialErr, peer)
	}
}

// SyncDevice is one device in the state route.
type SyncDevice struct {
	CopyDevice
	// Reach: why the last attempt could not reach it over the mesh, or "".
	Reach string `json:"reach,omitempty"`
	// Needs: "first_copy" while the box holds no token from it.
	Needs string `json:"needs,omitempty"`
}

// SyncReport is GET /api/box/sync.
type SyncReport struct {
	Busy      bool         `json:"busy"`
	Running   string       `json:"running,omitempty"`
	Round     bool         `json:"round"`
	LastRound int64        `json:"lastRound,omitempty"`
	NextRound int64        `json:"nextRound,omitempty"`
	Every     int64        `json:"everySeconds"`
	Devices   []SyncDevice `json:"devices"`
}

// Report is the per-device state for the state route. Only the first
// account sees the devices (the owner's device npubs, nv-mesh's errors):
// an added account gets the round's times and whether a copy is running
// (Tron #2385 L2).
func (s *Syncer) Report(ctx context.Context, first bool) (SyncReport, error) {
	s.init()
	r := SyncReport{Devices: []SyncDevice{}, Every: int64(orDur(s.Every, 15*time.Minute) / time.Second)}
	devices, err := s.Devices()
	if err != nil {
		return r, err
	}
	st, err := s.Engine.State(ctx, devices)
	if err != nil {
		return r, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r.Busy, r.Running, r.Round = st.Busy, st.Running, s.round
	if !s.lastRound.IsZero() {
		r.LastRound = s.lastRound.Unix()
	}
	if !s.nextRound.IsZero() {
		r.NextRound = s.nextRound.Unix()
	}
	if !first {
		r.Running = ""
		return r, nil
	}
	for _, d := range st.Devices {
		sd := SyncDevice{CopyDevice: d, Reach: s.dialErr[d.Peer]}
		if !d.Token {
			sd.Needs = "first_copy"
		}
		r.Devices = append(r.Devices, sd)
	}
	return r, nil
}

func shortNpub(npub string) string {
	if len(npub) > 16 {
		return fmt.Sprintf("%s…%s", npub[:10], npub[len(npub)-4:])
	}
	return npub
}
