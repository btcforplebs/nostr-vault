package box

import (
	"context"
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
}

// DevicesReport is GET /api/box/devices.
type DevicesReport struct {
	Box struct {
		Npub     string `json:"npub"`
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
// screen can poll without asking relays each time.
type Devices struct {
	OwnerHex string
	Key      DeviceKey
	Source   ServerListSource
	TTL      time.Duration

	mu     sync.Mutex
	cached *DevicesReport
	at     time.Time
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

	ev, src := d.Source.Newest(ctx, d.OwnerHex)
	r := BuildDevicesReport(d.Key, ev, src)
	d.mu.Lock()
	d.cached, d.at = &r, time.Now()
	d.mu.Unlock()
	return r
}

// BuildDevicesReport is the pure part of Report.
func BuildDevicesReport(key DeviceKey, list *nostr.Event, src string) DevicesReport {
	var r DevicesReport
	r.Box.Npub = key.Npub
	r.Box.Address = "fipsmesh://" + key.Npub + "/"
	r.Devices = []MeshEntry{}
	r.Source = "none"
	r.Checked = time.Now().Unix()
	if list != nil {
		r.ListAt = int64(list.CreatedAt)
		r.ListID = list.ID
		r.Source = src
		for _, e := range MeshEntries(list) {
			if e.Pubkey == key.Pubkey {
				e.This = true
				r.Box.Approved = true
			}
			r.Devices = append(r.Devices, e)
		}
	}
	if !r.Box.Approved {
		r.Hint = "On your phone: FIPS Mesh → My Devices → Add, paste " + r.Box.Npub + ", role Home vault."
	}
	return r
}
