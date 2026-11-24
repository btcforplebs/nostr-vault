package box

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
)

// PairedSet is the box's own paired devices (Desktop Vaults plan §2.3, Tron
// N1, N3, N5): box/paired-devices.json. Today the devices nv-mesh lets in
// come from the owner's kind 10063 (devices.go). A box has no pairing of its
// own, so Logen's plan gives it the same two-scan pairing a Mac has
// (pairing_box.go) and this file to remember the result. Pairing never uses
// an account key and publishes nothing: the set lives here alone.
//
// Cutover: the set is seeded once (Seed), from the devices the box already
// trusts, and only after a settled 10063 read (devices_seed.go). "Seeded" is
// never recorded from an empty result, so a box that starts with its relays
// down never seeds from nothing. Until P9b ships pair and Remove in the box
// web UI, mesh-devices.json keeps following the 10063s (plan §4): this file
// is written, not yet read for access.
type PairedSet struct {
	Path string

	mu sync.Mutex
}

// PairedDevice is one entry.
type PairedDevice struct {
	Npub string `json:"npub"`
	Name string `json:"name,omitempty"`
	// Role is the wire role from the hello; "" for a seeded device, whose
	// 10063 entry carried none.
	Role     string `json:"role,omitempty"`
	PairedAt int64  `json:"pairedAt"`
	// By is the account (npub) signed in to the box UI that confirmed the
	// pairing; "" for a seeded device.
	By string `json:"by,omitempty"`
	// From is "pair" or "seed".
	From string `json:"from"`
}

type pairedFile struct {
	Version  int            `json:"version"`
	SeededAt int64          `json:"seededAt,omitempty"`
	Devices  []PairedDevice `json:"devices"`
}

// ErrPairedOtherRole: the device is already paired under another role
// (contract §2, Tron 1): pairing never moves a device between roles.
var ErrPairedOtherRole = errors.New("this device is already paired under another role: remove it first")

func (p *PairedSet) load() (pairedFile, error) {
	f := pairedFile{Version: 1, Devices: []PairedDevice{}}
	b, err := os.ReadFile(p.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return f, nil
	}
	if err != nil {
		return f, fmt.Errorf("reading %s: %w", p.Path, err)
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return f, fmt.Errorf("reading %s: not a paired-devices file", p.Path)
	}
	if f.Devices == nil {
		f.Devices = []PairedDevice{}
	}
	return f, nil
}

func (p *PairedSet) save(f pairedFile) error {
	f.Version = 1
	body, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.Path), 0o700); err != nil {
		return err
	}
	return writeFileAtomic(p.Path, append(body, '\n'), 0o600)
}

// List is every paired device, in file order.
func (p *PairedSet) List() ([]PairedDevice, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	f, err := p.load()
	return f.Devices, err
}

// Npubs is the paired devices' npubs, the shape mesh-devices.json takes.
func (p *PairedSet) Npubs() ([]string, error) {
	list, err := p.List()
	out := make([]string, 0, len(list))
	for _, d := range list {
		out = append(out, d.Npub)
	}
	return out, err
}

// Seeded: the one-time seed has happened. An unreadable file reads as not
// seeded, and Seed then refuses to write over it (load's error).
func (p *PairedSet) Seeded() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	f, err := p.load()
	return err == nil && f.SeededAt > 0
}

// Seed records the devices the box trusts today as the paired set, once.
// Nothing happens (false) when the set is already seeded or npubs is empty:
// "seeded" is never written from an empty result (Tron N5).
func (p *PairedSet) Seed(npubs []string, now int64) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	f, err := p.load()
	if err != nil {
		return false, err
	}
	if f.SeededAt > 0 || len(npubs) == 0 {
		return false, nil
	}
	known := map[string]bool{}
	for _, d := range f.Devices {
		known[d.Npub] = true
	}
	for _, n := range npubs {
		if _, npub, err := ParseOwner(n); err == nil && !known[npub] {
			known[npub] = true
			f.Devices = append(f.Devices, PairedDevice{Npub: npub, PairedAt: now, From: "seed"})
		}
	}
	if len(f.Devices) == 0 {
		return false, nil
	}
	f.SeededAt = now
	return true, p.save(f)
}

// Add stores a device the owner confirmed. A device already paired under
// the same role (or seeded, with no role yet) is updated in place; one
// under another role is refused (ErrPairedOtherRole).
func (p *PairedSet) Add(d PairedDevice) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, npub, err := ParseOwner(d.Npub); err != nil {
		return fmt.Errorf("pairing: %w", err)
	} else {
		d.Npub = npub
	}
	f, err := p.load()
	if err != nil {
		return err
	}
	for i := range f.Devices {
		if f.Devices[i].Npub != d.Npub {
			continue
		}
		if f.Devices[i].Role != "" && f.Devices[i].Role != d.Role {
			return ErrPairedOtherRole
		}
		f.Devices[i].Role, f.Devices[i].Name, f.Devices[i].By = d.Role, d.Name, d.By
		if f.Devices[i].From == "seed" {
			f.Devices[i].From, f.Devices[i].PairedAt = "pair", d.PairedAt
		}
		return p.save(f)
	}
	d.From = "pair"
	f.Devices = append(f.Devices, d)
	return p.save(f)
}

// Remove drops a device. false when it was not in the set.
func (p *PairedSet) Remove(npub string) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, npub, err := ParseOwner(npub)
	if err != nil {
		return false, nil
	}
	f, err := p.load()
	if err != nil {
		return false, err
	}
	kept := f.Devices[:0]
	removed := false
	for _, d := range f.Devices {
		if d.Npub == npub {
			removed = true
			continue
		}
		kept = append(kept, d)
	}
	if !removed {
		return false, nil
	}
	f.Devices = kept
	return true, p.save(f)
}
