package box

import (
	"context"
	"log"
	"strings"
	"sync"

	"github.com/nbd-wtf/go-nostr"
)

// Devices on a box with several accounts (One Vault addendum A.3): a device
// is let in over the mesh when the box is approved, and the device listed,
// in the kind 10063 of any signed-in account, not only the first one. A
// device acts for the whole vault, as on a Mac: "per account" means which
// accounts may vouch for a device, not which account's data it sees.
// Watch-only accounts' lists never count.

// AccountList is one counted account's server list in DevicesReport.
type AccountList struct {
	Npub   string `json:"npub"`
	First  bool   `json:"first,omitempty"`
	ListAt int64  `json:"listAt"`
	ListID string `json:"listId,omitempty"`
	Source string `json:"source"`
}

// Readers: the hex keys whose server lists vouch for devices: the first
// account, then every signed-in account. A damaged accounts.json reads as
// the first account alone (fail closed, LoadAccounts).
func (s *AccountStore) Readers() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{s.OwnerHex}
	for _, n := range ListsFor(s.OwnerNpub, LoadAccounts(s.Path)).Readers[1:] {
		if pk, _, err := ParseOwner(n); err == nil {
			out = append(out, pk)
		}
	}
	return out
}

// counted: the first account, then the signed-in ones, each once.
func (d *Devices) counted() []string {
	owner := strings.ToLower(d.OwnerHex)
	out := []string{owner}
	if d.Accounts == nil {
		return out
	}
	seen := map[string]bool{owner: true}
	for _, pk := range d.Accounts() {
		pk = strings.ToLower(pk)
		if !seen[pk] {
			seen[pk] = true
			out = append(out, pk)
		}
	}
	return out
}

// read asks get for every counted account's newest list (all at once, so
// dead relays cost one timeout, not one per account), keeps each one that
// is newer than what is known, forgets accounts no longer counted, and
// writes mesh-devices.json from what is known.
func (d *Devices) read(ctx context.Context, get func(context.Context, string) (*nostr.Event, string)) DevicesReport {
	accounts := d.counted()
	found := make([]foundList, len(accounts))
	var wg sync.WaitGroup
	for i, pk := range accounts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ev, src := get(ctx, pk)
			found[i] = foundList{ev, src}
		}()
	}
	wg.Wait()

	d.wmu.Lock()
	defer d.wmu.Unlock()
	if d.lists == nil {
		d.lists = map[string]foundList{}
	}
	// Who counts now, not when the fetches began: a slow read that started
	// before an account was removed must not put its list (and its devices)
	// back after the removal's own read wrote them out (Tron #2376).
	now := d.counted()
	keep := map[string]bool{}
	for _, pk := range now {
		keep[pk] = true
	}
	for i, pk := range accounts {
		f := found[i]
		if f.ev == nil || !keep[pk] {
			continue
		}
		if old, ok := d.lists[pk]; ok && f.ev.CreatedAt < old.ev.CreatedAt {
			continue // older than the one known: never go back in time
		}
		d.lists[pk] = f
	}
	dropped := false
	for pk := range d.lists {
		if !keep[pk] {
			delete(d.lists, pk) // removed, or no longer signed in
			dropped = true
		}
	}
	npub, pubkey, _ := d.Mesh.Read()
	r := buildAccountsReport(npub, pubkey, now, d.lists)
	// What the file held before this read: the seed (below) takes it too.
	var before []string
	if d.Paired != nil && d.DevicesFile != "" {
		before = readMeshDevicesList(d.DevicesFile)
	}
	// With no list known the file is left as it was (an outage must not
	// drop every device), unless this read just forgot an account: then the
	// lists left, even none, are the whole truth, and the removed account's
	// devices must go now. A restart would not catch it later, since lists
	// starts empty (Tron #2376).
	if d.DevicesFile != "" && (len(d.lists) > 0 || dropped) {
		devices := MeshDevices(r)
		changed, err := writeMeshDevices(d.DevicesFile, devices)
		if err != nil {
			log.Printf("box: %v", err)
		} else if changed {
			log.Printf("box: mesh devices now %d (from %d account lists)", len(devices), len(d.lists))
		}
	}
	d.seedPaired(r, len(d.lists) > 0, len(d.lists) == len(now), before)
	return r
}

// buildAccountsReport merges the counted accounts' lists (accounts[0] is
// the first account) into one report: the box is approved if any list names
// it; every device any list names is in, once, with who vouched for it.
func buildAccountsReport(boxNpub, boxPubkey string, accounts []string, lists map[string]foundList) DevicesReport {
	first := lists[accounts[0]]
	r := BuildDevicesReport(boxNpub, boxPubkey, first.ev, orNone(first.src, first.ev))
	index := map[string]int{}
	for i := range r.Devices {
		index[r.Devices[i].Pubkey] = i
	}
	for i, pk := range accounts {
		f, ok := lists[pk]
		if !ok {
			continue
		}
		voucher := npubOfHex(pk)
		r.Lists = append(r.Lists, AccountList{Npub: voucher, First: i == 0, ListAt: int64(f.ev.CreatedAt), ListID: f.ev.ID, Source: f.src})
		for _, e := range MeshEntries(f.ev) {
			j, seen := index[e.Pubkey]
			if !seen {
				e.Approved = true
				if boxPubkey != "" && e.Pubkey == boxPubkey {
					e.Role, e.This = "homeVault", true
				}
				r.Devices = append(r.Devices, e)
				j = len(r.Devices) - 1
				index[e.Pubkey] = j
			}
			r.Devices[j].VouchedBy = append(r.Devices[j].VouchedBy, voucher)
			if r.Devices[j].This {
				r.Box.Approved = true
			}
		}
	}
	if r.Box.Approved && r.Box.Npub != "" {
		r.Hint = ""
	}
	return r
}

func orNone(src string, ev *nostr.Event) string {
	if ev == nil {
		return "none"
	}
	return src
}
