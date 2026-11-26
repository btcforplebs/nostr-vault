package wallet

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/elnosh/gonuts/cashu"
	"github.com/nbd-wtf/go-nostr"
)

// nutzapSetup: alice (funded) and bob (wallet key, 10019 published) at m.
func nutzapSetup(t *testing.T, m *testMint) (alice, bob *Wallet, aa, ba acct, info NutzapInfo) {
	t.Helper()
	aa, ba = newAcct(t), newAcct(t)
	alice = openWallet(t, &MemStore{})
	fund(t, alice, m, 100)
	if err := alice.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	bob = openWallet(t, &MemStore{})
	if err := bob.CreateWalletKey(); err != nil {
		t.Fatal(err)
	}
	fund(t, bob, m, 0)
	tpl, err := bob.NutzapInfoTemplate([]string{"wss://bob.example"})
	if err != nil {
		t.Fatal(err)
	}
	if tpl.Encrypt || tpl.Where != WherePublic {
		t.Fatalf("10019 must be public and plain: %+v", tpl)
	}
	info, err = ParseNutzapInfo(ba.sign(t, tpl), ba.pk)
	if err != nil {
		t.Fatal(err)
	}
	if info.Pubkey != bob.WalletPubkey() || info.Pubkey == ba.pk || len(info.Mints) != 1 {
		t.Fatalf("10019 %+v", info)
	}
	return
}

func sendNutzap(t *testing.T, alice *Wallet, aa acct, bob acct, info NutzapInfo, sats uint64) nostr.Event {
	t.Helper()
	tpl, _, err := alice.SendNutzap(ctx, NutzapRequest{Recipient: bob.pk, Info: info, Amount: sats,
		Comment: "great note", EventID: strings.Repeat("e", 64), EventKind: 1})
	if err != nil {
		t.Fatal(err)
	}
	if tpl.Kind != KindNutzap || tpl.Encrypt || tpl.Where != WhereRecipient || tpl.Relays[0] != "wss://bob.example" {
		t.Fatalf("9321 template %+v", tpl)
	}
	return aa.sign(t, tpl)
}

func TestNutzapSendVerifyRedeem(t *testing.T) {
	m := newTestMint(t, 0)
	alice, bob, aa, ba, info := nutzapSetup(t, m)
	ev := sendNutzap(t, alice, aa, ba, info, 21)
	wantBalance(t, alice, 79)

	nz, err := bob.VerifyNutzap(ctx, ev, ba.pk, info.Mints)
	if err != nil {
		t.Fatal(err)
	}
	if nz.Amount != 21 || nz.Sender != aa.pk || nz.Shared || nz.ZapOf != strings.Repeat("e", 64) {
		t.Fatalf("nutzap %+v", nz)
	}
	got, h, err := bob.RedeemNutzap(ctx, nz, "wss://bob.example")
	if err != nil || got != 21 {
		t.Fatalf("redeem %d %v", got, err)
	}
	wantBalance(t, bob, 21)
	if _, _, err := bob.RedeemNutzap(ctx, nz, ""); !errors.Is(err, ErrAlreadySpent) {
		t.Fatalf("second redeem: %v", err)
	}
	wantBalance(t, bob, 21)

	// History: redeemed is public, the rest encrypted.
	h.Created = []string{strings.Repeat("c", 64)}
	ht, err := bob.HistoryTemplate(h)
	if err != nil {
		t.Fatal(err)
	}
	hev := ba.sign(t, ht)
	if !RedeemedNutzaps([]nostr.Event{hev}, ba.pk)[ev.ID] {
		t.Fatal("redeemed nutzap not in public tags")
	}
	back, err := ParseHistory(ba.open(t, hev), ba.pk)
	if err != nil || !back.In || back.Amount != 21 || back.Created[0] != h.Created[0] ||
		back.Redeemed[0].EventID != ev.ID || back.Redeemed[0].Sender != aa.pk {
		t.Fatalf("history %+v %v", back, err)
	}
	if strings.Contains(hev.Content, "direction") {
		t.Fatal("history content not encrypted")
	}

	// Alice: the locked proofs are bob's; no 7375 of hers lists them,
	// and checkstate sees them claimed.
	v := &vault{}
	v.sync(t, aa, alice)
	for _, oe := range v.input(t, aa).Tokens {
		var c TokenContent
		json.Unmarshal([]byte(oe.Plaintext), &c)
		if c.Proofs.Amount() != 79 || c.ExportedAt != 0 {
			t.Fatalf("alice 7375 %d exported %d", c.Proofs.Amount(), c.ExportedAt)
		}
	}
	if rep, err := alice.CheckState(ctx, m.URL()); err != nil || rep.Claimed != 21 {
		t.Fatalf("claimed %+v %v", rep, err)
	}
}

func TestNutzapTwoDevicesRedeemOnce(t *testing.T) {
	m := newTestMint(t, 0)
	alice, bobPhone, aa, ba, info := nutzapSetup(t, m)
	v := &vault{}
	v.sync(t, ba, bobPhone)
	bobMac := openWallet(t, &MemStore{})
	restore(t, bobMac, v, ba)
	ev := sendNutzap(t, alice, aa, ba, info, 40)

	var wg sync.WaitGroup
	var got [2]uint64
	var errs [2]error
	for i, w := range []*Wallet{bobPhone, bobMac} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			nz, err := w.VerifyNutzap(ctx, ev, ba.pk, info.Mints)
			if err != nil {
				errs[i] = err
				return
			}
			got[i], _, errs[i] = w.RedeemNutzap(ctx, nz, "")
		}()
	}
	wg.Wait()
	wins := 0
	for i := range 2 {
		switch {
		case errs[i] == nil && got[i] == 40:
			wins++
		case errors.Is(errs[i], ErrAlreadySpent) || errors.Is(errs[i], ErrPending):
		default:
			t.Fatalf("device %d: %d %v", i, got[i], errs[i])
		}
	}
	if wins != 1 {
		t.Fatalf("%d devices redeemed", wins)
	}
	// Whatever is left in flight settles; together they hold 40, once.
	bobPhone.Recover(ctx)
	bobMac.Recover(ctx)
	v.sync(t, ba, bobPhone)
	v.sync(t, ba, bobMac)
	restore(t, bobPhone, v, ba)
	restore(t, bobMac, v, ba)
	wantBalance(t, bobPhone, 40)
	wantBalance(t, bobMac, 40)
}

func TestVerifyNutzapRejects(t *testing.T) {
	m := newTestMint(t, 0)
	alice, bob, aa, ba, info := nutzapSetup(t, m)
	good := sendNutzap(t, alice, aa, ba, info, 8)
	if _, err := bob.VerifyNutzap(ctx, good, ba.pk, info.Mints); err != nil {
		t.Fatal(err)
	}
	resign := func(f func(ev *nostr.Event)) nostr.Event {
		ev := good
		ev.Tags = append(nostr.Tags(nil), good.Tags...)
		f(&ev)
		if err := ev.Sign(aa.sk); err != nil {
			t.Fatal(err)
		}
		return ev
	}
	proofIdx := 0
	editProof := func(f func(p *cashu.Proof)) func(ev *nostr.Event) {
		return func(ev *nostr.Event) {
			var p cashu.Proof
			json.Unmarshal([]byte(ev.Tags[proofIdx][1]), &p)
			f(&p)
			b, _ := json.Marshal(p)
			ev.Tags[proofIdx] = nostr.Tag{"proof", string(b)}
		}
	}
	carol := newAcct(t)
	cases := map[string]nostr.Event{
		"tampered content": func() nostr.Event { ev := good; ev.Content = "changed"; return ev }(),
		"not to us":        resign(func(ev *nostr.Event) { ev.Tags[len(ev.Tags)-1] = nostr.Tag{"p", carol.pk} }),
		"unit msat":        resign(func(ev *nostr.Event) { ev.Tags = append(ev.Tags, nostr.Tag{"unit", "msat"}) }),
		"second mint":      resign(func(ev *nostr.Event) { ev.Tags = append(ev.Tags, nostr.Tag{"u", "https://other.example"}) }),
		"no dleq":          resign(editProof(func(p *cashu.Proof) { p.DLEQ = nil })),
		"bad dleq":         resign(editProof(func(p *cashu.Proof) { p.DLEQ.S = strings.Repeat("1", 64) })),
		"bad blinding r":   resign(editProof(func(p *cashu.Proof) { p.DLEQ.R = strings.Repeat("2", 64) })),
		"wrong amount":     resign(editProof(func(p *cashu.Proof) { p.Amount *= 2 })),
		"unknown keyset":   resign(editProof(func(p *cashu.Proof) { p.Id = "00ffffffffffffff" })),
		"unlocked secret":  resign(editProof(func(p *cashu.Proof) { p.Secret = strings.Repeat("3", 64) })),
	}
	for name, ev := range cases {
		if _, err := bob.VerifyNutzap(ctx, ev, ba.pk, info.Mints); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// A mint that is not in our 10019 list.
	if _, err := bob.VerifyNutzap(ctx, good, ba.pk, []string{"https://elsewhere.example"}); !errors.Is(err, ErrBadNutzap) {
		t.Errorf("foreign mint: %v", err)
	}
	// Locked to someone else's wallet key: carol can't claim bob's.
	carolW := openWallet(t, &MemStore{})
	carolW.CreateWalletKey()
	fund(t, carolW, m, 0)
	if _, err := carolW.VerifyNutzap(ctx, resign(func(ev *nostr.Event) { ev.Tags[len(ev.Tags)-1] = nostr.Tag{"p", carol.pk} }),
		carol.pk, info.Mints); !errors.Is(err, ErrBadNutzap) {
		t.Errorf("locked to bob, verified by carol: %v", err)
	}
	// Bob's balance never moved.
	wantBalance(t, bob, 0)
}

func TestSendNutzapNeedsSharedMint(t *testing.T) {
	m, other := newTestMint(t, 0), newTestMint(t, 0)
	alice, _, aa, ba, info := nutzapSetup(t, m)
	_ = aa
	info.Mints = []string{other.URL()}
	if _, _, err := alice.SendNutzap(ctx, NutzapRequest{Recipient: ba.pk, Info: info, Amount: 5}); !errors.Is(err, ErrNoSharedMint) {
		t.Fatalf("no shared mint: %v", err)
	}
	info.Mints = []string{m.URL()}
	if _, _, err := alice.SendNutzap(ctx, NutzapRequest{Recipient: ba.pk, Info: info, Amount: 500}); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("too much: %v", err)
	}
	wantBalance(t, alice, 100)
	if _, err := ParseNutzapInfo(ba.sign(t, Template{Kind: KindNutzapInfo, Tags: nostr.Tags{{"mint", m.URL(), "sat"}}}), ba.pk); !errors.Is(err, ErrNoNutzaps) {
		t.Fatalf("10019 without pubkey: %v", err)
	}
	if _, err := ParseNutzapInfo(ba.sign(t, Template{Kind: KindNutzapInfo, Tags: nostr.Tags{{"mint", m.URL(), "usd"}, {"pubkey", info.Pubkey}}}), ba.pk); !errors.Is(err, ErrNoNutzaps) {
		t.Fatalf("10019 usd only: %v", err)
	}
}

func TestSendNutzapRefusesMintWithoutDLEQ(t *testing.T) {
	m := newTestMint(t, 0)
	alice, _, _, ba, info := nutzapSetup(t, m)
	alice.mu.Lock()
	for i := range alice.state.Mints[m.URL()].Proofs {
		alice.state.Mints[m.URL()].Proofs[i].DLEQ = nil
	}
	alice.mu.Unlock()
	if _, _, err := alice.SendNutzap(ctx, NutzapRequest{Recipient: ba.pk, Info: info, Amount: 5}); !errors.Is(err, ErrNoSharedMint) {
		t.Fatalf("no-DLEQ mint used: %v", err)
	}
	wantBalance(t, alice, 100)
}
