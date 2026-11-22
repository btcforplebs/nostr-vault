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
	// The screens' fields (api.js). The list carries no names, roles or
	// last-seen times: name is "", role is known only for this box, and
	// listed means approved.
	Name     string `json:"name"`
	Role     string `json:"role,omitempty"`
	Approved bool   `json:"approved"`
	// VouchedBy: the npubs of the signed-in accounts whose lists name it.
	VouchedBy []string `json:"vouchedBy,omitempty"`
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
	// Lists: each counted account's list (ListAt, ListID and Source above
	// stay the first account's, as before accounts).
	Lists []AccountList `json:"lists,omitempty"`
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

// RelayServerLists asks the vault engine and the directory relays for the
// owner's list, and keeps the newest correctly signed one.
//
// Newest (the devices screen) asks them all at once. Poll (Devices.Run, every
// 30 s) asks the vault alone, and the directory relays only every
// DirectoryEvery, when the vault has no list (unless the directory had
// none either last time it was asked), or while the last directory
// answer was newer than the vault's (the vault isn't getting the owner's
// lists, so the relays stay on every poll until it catches up). Dialling the
// vault plus 4 directory relays every 30 s was 11,520 connects a day (Tidy's
// audit 11-20, L7).
type RelayServerLists struct {
	VaultURL  string // ws://127.0.0.1:<engine port>
	Directory []string
	Timeout   time.Duration
	// DirectoryEvery is how often Poll also asks the directory relays; 0 is
	// 10 minutes.
	DirectoryEvery time.Duration
	// First is the first account's hex key. It is never backed off: on a new
	// box nobody has a list yet, and the first approval may reach only the
	// directory relays.
	First string

	// Per account (the key asked about): a box polls the list of every
	// signed-in account (devices_accounts.go).
	mu      sync.Mutex
	dirAt   map[string]time.Time // the last time the directory relays were asked
	lagging map[string]bool      // their last answer was newer than the vault's
	// dirEmpty: the vault and the directory both had no list the last time
	// the directory was asked. Such an account (a signed-in one that never
	// made a 10063) waits DirectoryEvery for the next ask, not 30 s
	// (Tron #2376: L7's cost again per account otherwise).
	dirEmpty map[string]bool
}

type foundList struct {
	ev  *nostr.Event
	src string
}

func (s *RelayServerLists) Newest(ctx context.Context, ownerHex string) (*nostr.Event, string) {
	vault, dir := s.query(ctx, ownerHex, true, true)
	return s.settle(ownerHex, vault, dir, true)
}

// Poll is Newest for the background refresh: see the type.
func (s *RelayServerLists) Poll(ctx context.Context, ownerHex string) (*nostr.Event, string) {
	vault, _ := s.query(ctx, ownerHex, true, false)
	s.mu.Lock()
	every := s.DirectoryEvery
	if every == 0 {
		every = 10 * time.Minute
	}
	due := len(s.Directory) > 0 && ((vault == nil && (!s.dirEmpty[ownerHex] || strings.EqualFold(ownerHex, s.First))) || s.lagging[ownerHex] || time.Since(s.dirAt[ownerHex]) >= every)
	s.mu.Unlock()
	if !due {
		return s.settle(ownerHex, vault, nil, false)
	}
	_, dir := s.query(ctx, ownerHex, false, true)
	return s.settle(ownerHex, vault, dir, true)
}

// settle picks the newest of the two answers (a tie goes to the vault's own
// copy) and, when the directory was asked, notes when and whether it was ahead.
func (s *RelayServerLists) settle(ownerHex string, vault, dir *nostr.Event, askedDir bool) (*nostr.Event, string) {
	if askedDir {
		s.mu.Lock()
		if s.dirAt == nil {
			s.dirAt, s.lagging, s.dirEmpty = map[string]time.Time{}, map[string]bool{}, map[string]bool{}
		}
		s.dirAt[ownerHex] = time.Now()
		s.lagging[ownerHex] = dir != nil && (vault == nil || dir.CreatedAt > vault.CreatedAt)
		s.dirEmpty[ownerHex] = dir == nil && vault == nil
		s.mu.Unlock()
	}
	switch {
	case dir != nil && (vault == nil || dir.CreatedAt > vault.CreatedAt):
		return dir, "relays"
	case vault != nil:
		return vault, "vault"
	}
	return nil, "none"
}

// query asks the vault and/or the directory relays at once and returns each
// side's newest valid list.
func (s *RelayServerLists) query(ctx context.Context, ownerHex string, askVault, askDir bool) (vault, dir *nostr.Event) {
	timeout := s.Timeout
	if timeout == 0 {
		timeout = 6 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	filter := nostr.Filter{Kinds: []int{serverListKind}, Authors: []string{ownerHex}, Limit: 1}

	results := make(chan foundList, 1+len(s.Directory))
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
			results <- foundList{ev, src}
		}
	}
	if askVault && s.VaultURL != "" {
		wg.Add(1)
		go ask(s.VaultURL, "vault")
	}
	if askDir {
		for _, u := range s.Directory {
			wg.Add(1)
			go ask(u, "relays")
		}
	}
	go func() { wg.Wait(); close(results) }()

	for f := range results {
		if !validServerList(f.ev, ownerHex) {
			continue
		}
		if f.src == "vault" {
			if vault == nil || f.ev.CreatedAt > vault.CreatedAt {
				vault = f.ev
			}
		} else if dir == nil || f.ev.CreatedAt > dir.CreatedAt {
			dir = f.ev
		}
	}
	return vault, dir
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
// rewrites mesh-devices.json, so the signed-in accounts' 10063s are what let
// a device in over the mesh, and dropping it from them is what shuts it out
// (devices_accounts.go).
type Devices struct {
	OwnerHex string // the first account
	// Accounts: the hex keys whose lists count, the first account and every
	// signed-in account (AccountStore.Readers). Nil: the first account alone.
	// Watch-only accounts never count: whoever holds such a key could
	// otherwise pair a device and read everything.
	Accounts func() []string
	Mesh     MeshID // the box's one npub
	Source   ServerListSource
	TTL      time.Duration
	// DevicesFile is mesh-devices.json (NV_MESH_DEVICES). Empty: not written.
	DevicesFile string

	mu     sync.Mutex
	cached *DevicesReport
	at     time.Time

	// wmu guards lists, each account's newest list seen, which only moves
	// forward: a slow read of an older list (Run and Report race) never
	// undoes a newer, and an account whose list can't be read right now
	// keeps its last one. File writes happen under it too.
	wmu   sync.Mutex
	lists map[string]foundList
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

// Refresh reads every counted account's newest list now and writes
// mesh-devices.json from them. With no list known at all (relays and vault
// both silent since start) the file is left as it was: an outage must not
// drop every device. It does not fill Report's cache, so the screen never
// shows an answer older than its TTL.
func (d *Devices) Refresh(ctx context.Context) DevicesReport {
	return d.read(ctx, d.Source.Newest)
}

// ServerListPoller is a ServerListSource with a cheaper read for the
// background refresh (RelayServerLists.Poll).
type ServerListPoller interface {
	Poll(ctx context.Context, ownerHex string) (*nostr.Event, string)
}

// poll is Refresh for Run: the source's Poll when it has one.
func (d *Devices) poll(ctx context.Context) {
	if p, ok := d.Source.(ServerListPoller); ok {
		d.read(ctx, p.Poll)
		return
	}
	d.Refresh(ctx)
}

// Run refreshes every interval until ctx ends, so approvals and removals
// reach nv-mesh without anyone opening the devices screen.
func (d *Devices) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		d.poll(ctx)
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
