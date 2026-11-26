package wallet

// The built-in Cashu wallet's app bridge (design §2, PR E3): one JSON call
// surface over this package for Apple (C, haven-go/cashu_wallet_cshared.go) and
// Android (the same C exports through its JNI shim). The apps keep every
// signer step: they encrypt, sign and publish the templates this hands out,
// and pass decrypted events in. No Go callback, so bunker and Amber work.
//
// One wallet per state file (one per account). Open the same path twice and
// you get the same handle, so two callers never run two engines over one
// journal. Calls that reach a mint block (up to cashuCallTimeout): call them
// off the main thread.
//
// Every reply is {"ok":true,"result":…} or
// {"ok":false,"error":"…","code":"…"}; code is a stable name for the
// wallet's sentinel errors (cashuErrCodes) so the apps can branch on it.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/elnosh/gonuts/cashu"
	"github.com/nbd-wtf/go-nostr"
)

const cashuCallTimeout = 2 * time.Minute

type cashuWallets struct {
	mu       sync.Mutex
	next     int
	byHandle map[int]*cashuOpenWallet
	byPath   map[string]int
	// engines keeps the one Wallet per state file for the life of the
	// process. A close can come while a call that already got the engine is
	// still running; a reopen then must get that same engine, never a second
	// one that would save over the first one's writes.
	engines map[string]*Wallet
}

type cashuOpenWallet struct {
	w    *Wallet
	path string
	refs int
}

var cashuBridge = &cashuWallets{byHandle: map[int]*cashuOpenWallet{}, byPath: map[string]int{}, engines: map[string]*Wallet{}}

type cashuReply struct {
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
	Code   string `json:"code,omitempty"`
}

var cashuErrCodes = []struct {
	err  error
	code string
}{
	{ErrPending, "pending"},
	{ErrBusy, "busy"},
	{ErrOwnProofs, "own_proofs"},
	{ErrAlreadySpent, "already_spent"},
	{ErrNotEnough, "not_enough"},
	{ErrUnknownMint, "unknown_mint"},
	{ErrNotPaid, "not_paid"},
	{ErrNoChange, "no_change"},
	{ErrQuoteIssued, "quote_issued"},
	{ErrBadEvent, "bad_event"},
	{ErrKeyConflict, "key_conflict"},
	{ErrNutzapNoDLEQ, "nutzap_no_dleq"},
	{ErrRefundNotYet, "refund_not_yet"},
	{ErrNoNutzap, "no_nutzap"},
	{ErrNoNutzaps, "no_nutzaps"},
	{ErrNoSharedMint, "no_shared_mint"},
	{ErrBadNutzap, "bad_nutzap"},
	{ErrNothingToExport, "nothing_to_export"},
	{ErrNotAToken, "not_a_token"},
	{errCashuArgs, "bad_args"},
	{errCashuMethod, "unknown_method"},
	{errCashuHandle, "no_wallet"},
}

var (
	errCashuArgs   = errors.New("cashu bridge: bad arguments")
	errCashuMethod = errors.New("cashu bridge: unknown method")
	errCashuHandle = errors.New("cashu bridge: no open wallet with that handle")
)

func cashuJSON(result any, err error) []byte {
	r := cashuReply{OK: err == nil, Result: result}
	if err != nil {
		r.Error = err.Error()
		r.Code = "error"
		for _, c := range cashuErrCodes {
			if errors.Is(err, c.err) {
				r.Code = c.code
				break
			}
		}
	}
	b, mErr := json.Marshal(r)
	if mErr != nil {
		b, _ = json.Marshal(cashuReply{Error: mErr.Error(), Code: "error"})
	}
	return b
}

// BridgeOpen opens (or reuses) the wallet whose state lives at path, an
// absolute file path in the app's private storage. Result {"handle":n}.
func BridgeOpen(path string) []byte {
	if path == "" || !filepath.IsAbs(path) {
		return cashuJSON(nil, fmt.Errorf("%w: path must be absolute", errCashuArgs))
	}
	path = filepath.Clean(path)
	b := cashuBridge
	b.mu.Lock()
	defer b.mu.Unlock()
	if h, ok := b.byPath[path]; ok {
		b.byHandle[h].refs++
		return cashuJSON(map[string]int{"handle": h}, nil)
	}
	w := b.engines[path]
	if w == nil {
		var err error
		if w, err = Open(FileStore{Path: path}); err != nil {
			return cashuJSON(nil, err)
		}
		b.engines[path] = w
	}
	b.next++
	h := b.next
	b.byHandle[h] = &cashuOpenWallet{w: w, path: path, refs: 1}
	b.byPath[path] = h
	return cashuJSON(map[string]int{"handle": h}, nil)
}

// BridgeClose drops one open of handle; the handle goes at the last. The
// engine stays (see engines), so a reopen gets the same one.
func BridgeClose(handle int) {
	b := cashuBridge
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.byHandle[handle]
	if !ok {
		return
	}
	if o.refs--; o.refs <= 0 {
		delete(b.byHandle, handle)
		delete(b.byPath, o.path)
	}
}

func cashuWalletFor(handle int) (*Wallet, error) {
	b := cashuBridge
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.byHandle[handle]
	if !ok {
		return nil, errCashuHandle
	}
	return o.w, nil
}

// cashuArgs is every argument any method takes; each method reads its own.
type cashuArgs struct {
	Mint     string         `json:"mint"`
	Amount   uint64         `json:"amount"`
	Quote    string         `json:"quote"`    // claim_mint
	Bolt11   string         `json:"bolt11"`   // quote_melt
	Melt     *MeltQuote     `json:"melt"`     // melt: the quote_melt result
	LockTo   string         `json:"lock_to"`  // send
	Memo     string         `json:"memo"`     // send
	Reserved string         `json:"reserved"` // a Reserved set id
	Token    string         `json:"token"`    // receive_token: cashuA/cashuB
	Template *Template      `json:"template"` // commit_published
	EventID  string         `json:"event_id"` // commit_published
	History  *HistoryEntry  `json:"history"`  // history_template
	Restore  *RestoreInput  `json:"restore"`  // restore
	Relays   []string       `json:"relays"`   // nutzap_info_template
	Event    *nostr.Event   `json:"event"`    // verify_nutzap, redeem_nutzap
	Account  string         `json:"account"`  // verify/redeem_nutzap, redeemed_nutzaps
	Mints    []string       `json:"mints"`    // verify/redeem_nutzap: our 10019 mints
	Relay    string         `json:"relay"`    // redeem_nutzap: where the 9321 was seen
	Nutzap   *NutzapRequest `json:"nutzap"`   // send_nutzap
	Events   []nostr.Event  `json:"events"`   // redeemed_nutzaps: 7376s
}

func (a *cashuArgs) mint() string {
	if u, err := NormalizeMintURL(a.Mint); err == nil {
		return u
	}
	return a.Mint
}

func need(ok bool, what string) error {
	if !ok {
		return fmt.Errorf("%w: %s", errCashuArgs, what)
	}
	return nil
}

// BridgeCall runs one wallet method. args is a JSON object (or empty).
func BridgeCall(parent context.Context, handle int, method string, args []byte) (out []byte) {
	defer func() {
		// A panic must not cross the C boundary: it would take the app down.
		if p := recover(); p != nil {
			out = cashuJSON(nil, fmt.Errorf("cashu bridge: %s failed: %v", method, p))
		}
	}()
	res, err := cashuCall(parent, handle, method, args)
	if err != nil && method != "take_back" {
		res = nil // only take_back has a result worth reading on error (its Claim)
	}
	return cashuJSON(res, err)
}

func cashuCall(parent context.Context, handle int, method string, raw []byte) (any, error) {
	var a cashuArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &a); err != nil {
			return nil, fmt.Errorf("%w: %v", errCashuArgs, err)
		}
	}
	if method == "redeemed_nutzaps" { // needs no wallet
		if err := need(a.Account != "", "account"); err != nil {
			return nil, err
		}
		return RedeemedNutzaps(a.Events, a.Account), nil
	}
	w, err := cashuWalletFor(handle)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(parent, cashuCallTimeout)
	defer cancel()
	switch method {
	// Reads (no mint call).
	case "balance":
		return w.Balance(), nil
	case "mints":
		return w.Mints(), nil
	case "mint_quotes":
		return w.MintQuotes(), nil
	case "pending":
		return w.Pending(), nil
	case "reserved_sets":
		return w.ReservedSets(), nil
	case "waiting_tokens":
		return w.WaitingTokens(), nil
	case "unsent_nutzaps":
		return w.UnsentNutzaps(), nil
	case "wallet_pubkey":
		return map[string]any{"has_key": w.HasWalletKey(), "pubkey": w.WalletPubkey()}, nil

	// Mints.
	case "add_mint":
		if err := need(a.Mint != "", "mint"); err != nil {
			return nil, err
		}
		return w.AddMint(ctx, a.Mint)
	case "remove_mint":
		return nil, w.RemoveMint(a.mint())

	// Lightning in and out.
	case "request_mint":
		if err := need(a.Amount > 0, "amount"); err != nil {
			return nil, err
		}
		return w.RequestMint(ctx, a.mint(), a.Amount)
	case "claim_mint":
		if err := need(a.Quote != "", "quote"); err != nil {
			return nil, err
		}
		return w.ClaimMint(ctx, a.Quote)
	case "quote_melt":
		if err := need(a.Bolt11 != "", "bolt11"); err != nil {
			return nil, err
		}
		return w.QuoteMelt(ctx, a.mint(), a.Bolt11)
	case "melt":
		if err := need(a.Melt != nil, "melt"); err != nil {
			return nil, err
		}
		return w.Melt(ctx, *a.Melt)

	// Tokens.
	case "send":
		return w.Send(ctx, a.mint(), a.Amount, a.LockTo, a.Memo)
	case "receive_token":
		if err := need(len(a.Token) > 6, "token"); err != nil {
			return nil, err
		}
		tok, err := cashu.DecodeToken(a.Token)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errCashuArgs, err)
		}
		mint, err := NormalizeMintURL(tok.Mint())
		if err != nil {
			return nil, fmt.Errorf("%w: %v", errCashuArgs, err)
		}
		got, err := w.Receive(ctx, mint, tok.Proofs(), nil, a.Memo)
		return map[string]any{"mint": mint, "amount": got}, err
	case "export_token":
		return w.ExportToken(a.mint())
	case "token_for":
		return w.TokenFor(a.Reserved)
	case "take_back":
		return w.TakeBack(ctx, a.Reserved)
	case "reclaim":
		return w.Reclaim(ctx, a.Reserved)
	case "check_state":
		return w.CheckState(ctx, a.mint())
	case "recover":
		return w.Recover(ctx), nil

	// NIP-60 events.
	case "create_wallet_key":
		return nil, w.CreateWalletKey()
	case "restore":
		if err := need(a.Restore != nil, "restore"); err != nil {
			return nil, err
		}
		return w.Restore(ctx, *a.Restore)
	case "rollover":
		return w.Rollover()
	case "commit_published":
		if err := need(a.Template != nil, "template"); err != nil {
			return nil, err
		}
		return nil, w.CommitPublished(*a.Template, a.EventID)
	case "history_template":
		if err := need(a.History != nil, "history"); err != nil {
			return nil, err
		}
		return w.HistoryTemplate(*a.History)

	// NIP-61 nutzaps.
	case "nutzap_info_template":
		return w.NutzapInfoTemplate(a.Relays)
	case "verify_nutzap":
		if err := need(a.Event != nil && a.Account != "", "event, account"); err != nil {
			return nil, err
		}
		return w.VerifyNutzap(ctx, *a.Event, a.Account, a.Mints)
	case "redeem_nutzap":
		// Verify again here, so the app hands over the 9321 itself and never
		// a Nutzap it built.
		if err := need(a.Event != nil && a.Account != "", "event, account"); err != nil {
			return nil, err
		}
		nz, err := w.VerifyNutzap(ctx, *a.Event, a.Account, a.Mints)
		if err != nil {
			return nil, err
		}
		got, h, err := w.RedeemNutzap(ctx, nz, a.Relay)
		if err != nil {
			return nil, err
		}
		return map[string]any{"amount": got, "history": h}, nil
	case "send_nutzap":
		if err := need(a.Nutzap != nil, "nutzap"); err != nil {
			return nil, err
		}
		tpl, r, err := w.SendNutzap(ctx, *a.Nutzap)
		if err != nil {
			return nil, err
		}
		return map[string]any{"template": tpl, "reserved": r}, nil
	case "nutzap_template_for":
		return w.NutzapTemplateFor(a.Reserved)
	}
	return nil, fmt.Errorf("%w: %q", errCashuMethod, method)
}
