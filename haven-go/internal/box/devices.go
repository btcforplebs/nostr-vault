package box

import (
	"context"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// My Devices, as the box sees it. The phone approves the box the way it
// approves a Mac or a Moto: the owner adds the box's npub in My Devices as
// "Home vault", and the phone republishes the owner's kind 10063 with
// fipsmesh://<box npub>/ in it (HomeVaultLogic.phoneMeshEntries). The box
// reads that list. Listed = approved; dropped from the newest list =
// revoked. The other fipsmesh entries in the same list are the owner's other
// mesh devices (phones' photo nodes, the Mac, an older home vault).

const serverListKind = 10063

// MeshEntry is one fipsmesh:// entry of the owner's server list.
type MeshEntry struct {
	Npub   string `json:"npub"`
	Pubkey string `json:"pubkey"`
	This   bool   `json:"thisBox,omitempty"`
	// The screens' fields (api.js). The list carries no names, roles or
	// last-seen times: name is "", role is known only for this box, and
	// listed means approved.
	Name     string `json:"name"`
	Role     string `json:"role,omitempty"`
	Approved bool   `json:"approved"`
}

// DevicesReport is GET /api/box/devices.
type DevicesReport struct {
	Box struct {
		Npub     string `json:"npub"`
		Name     string `json:"name"`
		Approved bool   `json:"approved"`
		// Address is what the owner pastes into My Devices.
		Address string `json:"address"`
	} `json:"box"`
	Devices []MeshEntry `json:"devices"`
	// ListAt is the created_at of the server list read; 0 when none was found.
	ListAt  int64  `json:"listAt"`
	ListID  string `json:"listId,omitempty"`
	Source  string `json:"source"` // "vault", "relays" or "none"
	Checked int64  `json:"checkedAt"`
	Hint    string `json:"hint,omitempty"`
}

// MeshEntries reads the fipsmesh entries of a kind-10063 event. Only the
// exact form counts: lowercase "fipsmesh://", a lowercase npub that decodes,
// then "/", optionally followed by a query (NIP-F1). Anything else is skipped.
func MeshEntries(ev *nostr.Event) []MeshEntry {
	var out []MeshEntry
	seen := map[string]bool{}
	for _, t := range ev.Tags {
		if len(t) < 2 || t[0] != "server" {
			continue
		}
		e, ok := parseMeshAddress(t[1])
		if !ok || seen[e.Pubkey] {
			continue
		}
		seen[e.Pubkey] = true
		out = append(out, e)
	}
	return out
}

func parseMeshAddress(v string) (MeshEntry, bool) {
	rest, ok := strings.CutPrefix(v, "fipsmesh://")
	if !ok {
		return MeshEntry{}, false
	}
	slash := strings.IndexByte(rest, '/')
	if slash < 0 {
		return MeshEntry{}, false
	}
	host, tail := rest[:slash], rest[slash:]
	if tail != "/" && !strings.HasPrefix(tail, "/?") {
		return MeshEntry{}, false // other paths are reserved
	}
	if host != strings.ToLower(host) || !strings.HasPrefix(host, "npub1") {
		return MeshEntry{}, false
	}
	prefix, val, err := nip19.Decode(host)
	if err != nil || prefix != "npub" {
		return MeshEntry{}, false
	}
	return MeshEntry{Npub: host, Pubkey: val.(string)}, true
}

// ServerListSource finds the owner's newest kind 10063.
type ServerListSource interface {
	// Newest returns the owner's newest valid 10063 and where it came from
	// ("vault" or "relays"), or nil.
	Newest(ctx context.Context, ownerHex string) (*nostr.Event, string)
}

// RelayServerLists asks the vault engine first and the directory relays
// alongside it, and keeps the newest correctly signed list by the owner.
type RelayServerLists struct {
	VaultURL  string // ws://127.0.0.1:<engine port>
	Directory []string
	Timeout   time.Duration
}

func (s *RelayServerLists) Newest(ctx context.Context, ownerHex string) (*nostr.Event, string) {
	timeout := s.Timeout
	if timeout == 0 {
		timeout = 6 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	filter := nostr.Filter{Kinds: []int{serverListKind}, Authors: []string{ownerHex}, Limit: 1}

	type found struct {
		ev  *nostr.Event
		src string
	}
	results := make(chan found, 1+len(s.Directory))
	var wg sync.WaitGroup
	ask := func(url, src string) {
		defer wg.Done()
		r, err := nostr.RelayConnect(ctx, url)
		if err != nil {
			return
		}
		defer r.Close()
		evs, err := r.QuerySync(ctx, filter)
		if err != nil {
			return
		}
		for _, ev := range evs {
			results <- found{ev, src}
		}
	}
	if s.VaultURL != "" {
		wg.Add(1)
		go ask(s.VaultURL, "vault")
	}
	for _, u := range s.Directory {
		wg.Add(1)
		go ask(u, "relays")
	}
	go func() { wg.Wait(); close(results) }()

	var best *nostr.Event
	src := "none"
	for f := range results {
		if !validServerList(f.ev, ownerHex) {
			continue
		}
		// Newest wins; on a tie the vault's own copy is preferred.
		if best == nil || f.ev.CreatedAt > best.CreatedAt || (f.ev.CreatedAt == best.CreatedAt && f.src == "vault") {
			best, src = f.ev, f.src
		}
	}
	return best, src
}

func validServerList(ev *nostr.Event, ownerHex string) bool {
	if ev == nil || ev.Kind != serverListKind || !strings.EqualFold(ev.PubKey, ownerHex) {
		return false
	}
	if ev.CreatedAt.Time().After(time.Now().Add(10 * time.Minute)) {
		return false // a list from the future would pin approval forever
	}
	ok, err := ev.CheckSignature()
	return err == nil && ok
}

// Devices builds DevicesReport, caching the answer for a minute so the
// screen can poll without asking relays each time. Each fresh read also
// rewrites mesh-devices.json, so the owner's 10063 is what lets a device in
// over the mesh, and dropping it from the list is what shuts it out.
type Devices struct {
	OwnerHex string
	Mesh     MeshID // the box's one npub
	Source   ServerListSource
	TTL      time.Duration
	// DevicesFile is mesh-devices.json (NV_MESH_DEVICES). Empty: not written.
	DevicesFile string

	mu     sync.Mutex
	cached *DevicesReport
	at     time.Time

	// wmu serialises file writes; wroteAt is the list last written, so a
	// slow read of an older list (Run and Report race) never undoes a newer.
	wmu     sync.Mutex
	wroteAt nostr.Timestamp
}

func (d *Devices) Report(ctx context.Context) DevicesReport {
	ttl := d.TTL
	if ttl == 0 {
		ttl = time.Minute
	}
	d.mu.Lock()
	if d.cached != nil && time.Since(d.at) < ttl {
		r := *d.cached
		d.mu.Unlock()
		return r
	}
	d.mu.Unlock()
	r := d.Refresh(ctx)
	d.mu.Lock()
	d.cached, d.at = &r, time.Now()
	d.mu.Unlock()
	return r
}

// Refresh reads the owner's newest list now and writes mesh-devices.json
// from it. With no list found (relays and vault both silent) the file is
// left as it was: an outage must not drop every device. It does not fill
// Report's cache, so the screen never shows an answer older than its TTL.
func (d *Devices) Refresh(ctx context.Context) DevicesReport {
	ev, src := d.Source.Newest(ctx, d.OwnerHex)
	npub, pubkey, _ := d.Mesh.Read()
	r := BuildDevicesReport(npub, pubkey, ev, src)
	if d.DevicesFile != "" && ev != nil {
		d.writeDevices(r, ev)
	}
	return r
}

func (d *Devices) writeDevices(r DevicesReport, ev *nostr.Event) {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	if ev.CreatedAt < d.wroteAt {
		return
	}
	devices := MeshDevices(r)
	changed, err := writeMeshDevices(d.DevicesFile, devices)
	if err != nil {
		log.Printf("box: %v", err)
		return
	}
	d.wroteAt = ev.CreatedAt
	if changed {
		log.Printf("box: mesh devices now %d (owner's list %s)", len(devices), ev.ID)
	}
}

// Run refreshes every interval until ctx ends, so approvals and removals
// reach nv-mesh without anyone opening the devices screen.
func (d *Devices) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		d.Refresh(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// BuildDevicesReport is the pure part of Report. boxNpub is the box's mesh
// npub, "" while nv-mesh has not made its key yet.
func BuildDevicesReport(boxNpub, boxPubkey string, list *nostr.Event, src string) DevicesReport {
	var r DevicesReport
	r.Box.Npub = boxNpub
	r.Box.Name = "Nostr Vault box"
	if boxNpub != "" {
		r.Box.Address = "fipsmesh://" + boxNpub + "/"
	}
	r.Devices = []MeshEntry{}
	r.Source = "none"
	r.Checked = time.Now().Unix()
	if list != nil {
		r.ListAt = int64(list.CreatedAt)
		r.ListID = list.ID
		r.Source = src
		for _, e := range MeshEntries(list) {
			e.Approved = true
			if boxPubkey != "" && e.Pubkey == boxPubkey {
				e.Role = "homeVault"
				e.This = true
				r.Box.Approved = true
			}
			r.Devices = append(r.Devices, e)
		}
	}
	switch {
	case boxNpub == "":
		r.Hint = "The box's mesh is starting. Its address shows here once it is up."
	case !r.Box.Approved:
		r.Hint = "On your phone: FIPS Mesh → My Devices → Add, paste " + r.Box.Npub + ", role Home vault."
	}
	return r
}
