package wallet

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

type bridgeReply struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
	Code   string          `json:"code"`
}

func bcall(t *testing.T, h int, method string, args any, out any) bridgeReply {
	t.Helper()
	var raw []byte
	if args != nil {
		raw, _ = json.Marshal(args)
	}
	var r bridgeReply
	if err := json.Unmarshal(BridgeCall(ctx, h, method, raw), &r); err != nil {
		t.Fatal(err)
	}
	if out != nil && r.OK {
		if err := json.Unmarshal(r.Result, out); err != nil {
			t.Fatalf("%s result: %v", method, err)
		}
	}
	return r
}

func bopen(t *testing.T, path string) int {
	t.Helper()
	var r struct {
		OK     bool `json:"ok"`
		Result struct {
			Handle int `json:"handle"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(BridgeOpen(path), &r); err != nil || !r.OK || r.Result.Handle == 0 {
		t.Fatalf("open %s: %+v %v", path, r, err)
	}
	return r.Result.Handle
}

func bfund(t *testing.T, h int, m *testMint, amount uint64) {
	t.Helper()
	if r := bcall(t, h, "add_mint", map[string]any{"mint": m.URL() + "/"}, nil); !r.OK {
		t.Fatalf("add_mint %+v", r)
	}
	if amount == 0 {
		return
	}
	var q MintQuote
	if r := bcall(t, h, "request_mint", map[string]any{"mint": m.URL(), "amount": amount}, &q); !r.OK {
		t.Fatalf("request_mint %+v", r)
	}
	if r := bcall(t, h, "claim_mint", map[string]any{"quote": q.ID}, nil); r.Code != "not_paid" {
		t.Fatalf("claim before pay %+v", r)
	}
	m.payMintQuote(q.ID)
	var got uint64
	if r := bcall(t, h, "claim_mint", map[string]any{"quote": q.ID}, &got); !r.OK || got != amount {
		t.Fatalf("claim_mint %d %+v", got, r)
	}
}

func TestBridgeExportPartialClaimTakeBack(t *testing.T) {
	m := newTestMint(t, 0)
	dir := t.TempDir()
	alice := bopen(t, filepath.Join(dir, "alice", "wallet.json"))
	defer BridgeClose(alice)
	if again := bopen(t, filepath.Join(dir, "alice", "..", "alice", "wallet.json")); again != alice {
		t.Fatalf("same file, new handle %d != %d", again, alice)
	} else {
		BridgeClose(again)
	}
	bob := bopen(t, filepath.Join(dir, "bob", "wallet.json"))
	defer BridgeClose(bob)
	bfund(t, alice, m, 100)
	bfund(t, bob, m, 0)

	var exp ExportedToken
	if r := bcall(t, alice, "export_token", map[string]any{"mint": m.URL()}, &exp); !r.OK || exp.Amount != 100 {
		t.Fatalf("export %+v %+v", exp, r)
	}
	var b Balance
	bcall(t, alice, "balance", nil, &b)
	if b.Total != 0 || b.ReservedPerMint[m.URL()] != 100 {
		t.Fatalf("balance after export %+v", b)
	}
	if r := bcall(t, alice, "export_token", map[string]any{"mint": m.URL()}, nil); r.Code != "nothing_to_export" {
		t.Fatalf("second export %+v", r)
	}

	// Bob claims part of the token: rebuild a cashuB holding only the 64.
	_, proofs := decodeExport(t, exp.Token)
	part, err := encodeToken(m.URL(), pick(proofs, 64))
	if err != nil {
		t.Fatal(err)
	}
	var recv struct {
		Amount uint64 `json:"amount"`
	}
	if r := bcall(t, bob, "receive_token", map[string]any{"token": part}, &recv); !r.OK || recv.Amount != 64 {
		t.Fatalf("bob receive %+v %+v", recv, r)
	}

	var rep CheckReport
	if r := bcall(t, alice, "check_state", map[string]any{"mint": m.URL()}, &rep); !r.OK || len(rep.Claims) != 1 ||
		rep.Claims[0].Amount != 64 || rep.Claims[0].Done {
		t.Fatalf("check_state %+v %+v", rep, r)
	}
	var tpl Template
	if r := bcall(t, alice, "history_template", map[string]any{"history": rep.Claims[0].History}, &tpl); !r.OK || tpl.Kind != KindHistory {
		t.Fatalf("history_template %+v", r)
	}
	var plan RolloverPlan
	if r := bcall(t, alice, "rollover", nil, &plan); !r.OK || len(plan.Events) == 0 {
		t.Fatalf("rollover %+v", r)
	}

	var res TakeBackResult
	if r := bcall(t, alice, "take_back", map[string]any{"reserved": exp.Reserved}, &res); !r.OK || res.Returned != 36 {
		t.Fatalf("take_back %+v %+v", res, r)
	}
	bcall(t, alice, "balance", nil, &b)
	if b.Total != 36 || b.Reserved != 0 {
		t.Fatalf("balance after take back %+v", b)
	}
	// Bob's copy of the full token is worthless now.
	if r := bcall(t, bob, "receive_token", map[string]any{"token": exp.Token}, nil); r.Code != "already_spent" {
		t.Fatalf("stale token %+v", r)
	}
	// The state survives a reopen from disk.
	BridgeClose(alice)
	alice = bopen(t, filepath.Join(dir, "alice", "wallet.json"))
	bcall(t, alice, "balance", nil, &b)
	if b.Total != 36 {
		t.Fatalf("balance after reopen %+v", b)
	}
}

func TestBridgeTakeBackClaimedKeepsResult(t *testing.T) {
	m := newTestMint(t, 0)
	dir := t.TempDir()
	alice := bopen(t, filepath.Join(dir, "a.json"))
	defer BridgeClose(alice)
	bob := bopen(t, filepath.Join(dir, "b.json"))
	defer BridgeClose(bob)
	bfund(t, alice, m, 20)
	bfund(t, bob, m, 0)
	var exp ExportedToken
	bcall(t, alice, "export_token", map[string]any{"mint": m.URL()}, &exp)
	if r := bcall(t, bob, "receive_token", map[string]any{"token": exp.Token}, nil); !r.OK {
		t.Fatalf("bob %+v", r)
	}
	r := bcall(t, alice, "take_back", map[string]any{"reserved": exp.Reserved}, nil)
	var res TakeBackResult
	json.Unmarshal(r.Result, &res)
	if r.OK || r.Code != "already_spent" || res.Claim == nil || res.Claim.Amount != 20 || !res.Claim.Done {
		t.Fatalf("take_back of claimed %+v %+v", r, res)
	}
}

func TestBridgeRefusals(t *testing.T) {
	if r := bcall(t, 9999, "balance", nil, nil); r.Code != "no_wallet" {
		t.Fatalf("bad handle %+v", r)
	}
	var r bridgeReply
	json.Unmarshal(BridgeOpen("relative/wallet.json"), &r)
	if r.OK || r.Code != "bad_args" {
		t.Fatalf("relative path %+v", r)
	}
	h := bopen(t, filepath.Join(t.TempDir(), "w.json"))
	defer BridgeClose(h)
	if r := bcall(t, h, "nope", nil, nil); r.Code != "unknown_method" {
		t.Fatalf("unknown method %+v", r)
	}
	if r := bcall(t, h, "export_token", map[string]any{"mint": "https://mint.example"}, nil); r.Code != "unknown_mint" {
		t.Fatalf("unknown mint %+v", r)
	}
	if r := bcall(t, h, "receive_token", map[string]any{"token": "cashuBnotatoken"}, nil); r.Code != "bad_args" {
		t.Fatalf("bad token %+v", r)
	}
	raw := BridgeCall(ctx, h, "balance", []byte("{not json"))
	json.Unmarshal(raw, &r)
	if r.Code != "bad_args" {
		t.Fatalf("bad json %+v", r)
	}
	if r := bcall(t, h, "request_mint", map[string]any{"mint": "https://mint.example"}, nil); r.Code != "bad_args" {
		t.Fatalf("no amount %+v", r)
	}
	if r := bcall(t, h, "wallet_pubkey", nil, nil); !r.OK {
		t.Fatalf("wallet_pubkey %+v", r)
	}
}
