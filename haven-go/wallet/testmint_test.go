package wallet

// A local test mint: a real Cashu mint's HTTP API (NUT-01..09, 11, 12) on
// httptest, signing with gonuts' BDHKE and DLEQ code, with a fake Lightning
// backend and fault switches (lost replies, pending payments, no restore).

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/btcsuite/btcd/btcutil/hdkeychain"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut01"
	"github.com/elnosh/gonuts/cashu/nuts/nut02"
	"github.com/elnosh/gonuts/cashu/nuts/nut03"
	"github.com/elnosh/gonuts/cashu/nuts/nut04"
	"github.com/elnosh/gonuts/cashu/nuts/nut05"
	"github.com/elnosh/gonuts/cashu/nuts/nut06"
	"github.com/elnosh/gonuts/cashu/nuts/nut07"
	"github.com/elnosh/gonuts/cashu/nuts/nut09"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
	"github.com/elnosh/gonuts/cashu/nuts/nut11"
	"github.com/elnosh/gonuts/crypto"
)

type tmMintQuote struct {
	amount uint64
	state  nut04.State
}

type tmMeltQuote struct {
	amount, feeReserve uint64
	state              nut05.State
	inputs             cashu.Proofs
	outputs            cashu.BlindedMessages
	change             cashu.BlindedSignatures
}

type testMint struct {
	t   testing.TB
	srv *httptest.Server

	mu         sync.Mutex
	ks         *crypto.MintKeyset
	spent      map[string]bool // Y
	pending    map[string]bool // Y
	signed     map[string]cashu.BlindedSignature
	signedOut  map[string]cashu.BlindedMessage
	mintQuotes map[string]*tmMintQuote
	meltQuotes map[string]*tmMeltQuote
	invoices   map[string]uint64
	n          int

	// knobs
	feeReserve  uint64         // melt fee reserve
	actualFee   uint64         // what Lightning really costs
	meltPending bool           // melts stay PENDING until settleMelt
	noRestore   bool           // /v1/restore answers 400 (no NUT-09)
	noChange    bool           // info does not list NUT-08
	meltFail    bool           // Lightning payments fail (quote back to UNPAID)
	badDLEQ     bool           // signatures carry a wrong DLEQ
	dropReply   map[string]int // path -> how many replies to drop after doing the work
	calls       map[string]int
}

func newTestMint(t testing.TB, inputFeePpk uint) *testMint {
	seed := sha256.Sum256([]byte(t.Name() + "-mint-seed"))
	master, err := hdkeychain.NewMaster(seed[:], &chaincfg.MainNetParams)
	if err != nil {
		t.Fatal(err)
	}
	ks, err := crypto.GenerateKeyset(master, 0, inputFeePpk)
	if err != nil {
		t.Fatal(err)
	}
	m := &testMint{
		t: t, ks: ks,
		spent: map[string]bool{}, pending: map[string]bool{},
		signed: map[string]cashu.BlindedSignature{}, signedOut: map[string]cashu.BlindedMessage{},
		mintQuotes: map[string]*tmMintQuote{}, meltQuotes: map[string]*tmMeltQuote{},
		invoices: map[string]uint64{}, feeReserve: 4, actualFee: 1,
		dropReply: map[string]int{}, calls: map[string]int{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", m.info)
	mux.HandleFunc("GET /v1/keysets", m.keysets)
	mux.HandleFunc("GET /v1/keys/{id}", m.keys)
	mux.HandleFunc("POST /v1/mint/quote/bolt11", m.mintQuote)
	mux.HandleFunc("GET /v1/mint/quote/bolt11/{id}", m.mintQuoteState)
	mux.HandleFunc("POST /v1/mint/bolt11", m.mint)
	mux.HandleFunc("POST /v1/swap", m.swap)
	mux.HandleFunc("POST /v1/melt/quote/bolt11", m.meltQuote)
	mux.HandleFunc("GET /v1/melt/quote/bolt11/{id}", m.meltQuoteState)
	mux.HandleFunc("POST /v1/melt/bolt11", m.melt)
	mux.HandleFunc("POST /v1/checkstate", m.checkstate)
	mux.HandleFunc("POST /v1/restore", m.restore)
	m.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, r)
		m.mu.Lock()
		m.calls[r.URL.Path]++
		drop := m.dropReply[r.URL.Path] > 0
		if drop {
			m.dropReply[r.URL.Path]--
		}
		m.mu.Unlock()
		if drop {
			panic(http.ErrAbortHandler) // work done, reply lost
		}
		for k, v := range rec.Header() {
			w.Header()[k] = v
		}
		w.WriteHeader(rec.Code)
		w.Write(rec.Body.Bytes())
	}))
	t.Cleanup(m.srv.Close)
	return m
}

func (m *testMint) URL() string { return m.srv.URL }

func (m *testMint) callCount(path string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls[path]
}

// payMintQuote is the fake Lightning payment of a receive invoice.
func (m *testMint) payMintQuote(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.mintQuotes[id].state = nut04.Paid
}

// invoice registers a fake bolt11 for amount sats.
func (m *testMint) invoice(amount uint64) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.n++
	inv := fmt.Sprintf("lnbctest%d", m.n)
	m.invoices[inv] = amount
	return inv
}

func reply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func refuse(w http.ResponseWriter, e cashu.Error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	json.NewEncoder(w).Encode(e)
}

func decode(r *http.Request, v any) bool { return json.NewDecoder(r.Body).Decode(v) == nil }

func (m *testMint) info(w http.ResponseWriter, r *http.Request) {
	var mi nut06.MintInfo
	mi.Name = "Test mint"
	mi.Version = "test/1"
	mi.Nuts.Nut07.Supported = true
	mi.Nuts.Nut08.Supported = !m.noChange
	mi.Nuts.Nut09.Supported = !m.noRestore
	mi.Nuts.Nut11.Supported = true
	mi.Nuts.Nut12.Supported = true
	reply(w, mi)
}

func (m *testMint) keysets(w http.ResponseWriter, r *http.Request) {
	reply(w, nut02.GetKeysetsResponse{Keysets: []nut02.Keyset{{Id: m.ks.Id, Unit: "sat", Active: true, InputFeePpk: m.ks.InputFeePpk}}})
}

func (m *testMint) keys(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("id") != m.ks.Id {
		refuse(w, cashu.UnknownKeysetErr)
		return
	}
	reply(w, nut01.GetKeysResponse{Keysets: []nut01.Keyset{{Id: m.ks.Id, Unit: "sat", Keys: m.ks.DerivePublic()}}})
}

func (m *testMint) mintQuote(w http.ResponseWriter, r *http.Request) {
	var req nut04.PostMintQuoteBolt11Request
	if !decode(r, &req) || req.Amount == 0 {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.n++
	id := fmt.Sprintf("mq%d", m.n)
	m.mintQuotes[id] = &tmMintQuote{amount: req.Amount, state: nut04.Unpaid}
	reply(w, &nut04.PostMintQuoteBolt11Response{Quote: id, Request: "lnbcpayme" + id, State: nut04.Unpaid})
}

func (m *testMint) mintQuoteState(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q := m.mintQuotes[r.PathValue("id")]
	if q == nil {
		refuse(w, cashu.QuoteNotExistErr)
		return
	}
	reply(w, &quoteStatus{Quote: r.PathValue("id"), Request: "x", State: q.state.String(), Amount: q.amount})
}

func (m *testMint) mint(w http.ResponseWriter, r *http.Request) {
	var req nut04.PostMintBolt11Request
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	q := m.mintQuotes[req.Quote]
	switch {
	case q == nil:
		refuse(w, cashu.QuoteNotExistErr)
		return
	case q.state == nut04.Issued:
		refuse(w, cashu.MintQuoteAlreadyIssued)
		return
	case q.state != nut04.Paid:
		refuse(w, cashu.MintQuoteRequestNotPaid)
		return
	case req.Outputs.Amount() != q.amount:
		refuse(w, cashu.OutputsOverQuoteAmountErr)
		return
	}
	sigs, cerr := m.signLocked(req.Outputs)
	if cerr != nil {
		refuse(w, *cerr)
		return
	}
	q.state = nut04.Issued
	reply(w, nut04.PostMintBolt11Response{Signatures: sigs})
}

func (m *testMint) swap(w http.ResponseWriter, r *http.Request) {
	var req nut03.PostSwapRequest
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	ys, cerr := m.verifyInputsLocked(req.Inputs)
	if cerr != nil {
		refuse(w, *cerr)
		return
	}
	if req.Inputs.Amount()-m.feeLocked(req.Inputs) != req.Outputs.Amount() {
		refuse(w, cashu.InsufficientProofsAmount)
		return
	}
	sigs, cerr := m.signLocked(req.Outputs)
	if cerr != nil {
		refuse(w, *cerr)
		return
	}
	for _, y := range ys {
		m.spent[y] = true
	}
	reply(w, nut03.PostSwapResponse{Signatures: sigs})
}

func (m *testMint) meltQuote(w http.ResponseWriter, r *http.Request) {
	var req nut05.PostMeltQuoteBolt11Request
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	amt, ok := m.invoices[req.Request]
	if !ok {
		refuse(w, cashu.Error{Detail: "bad invoice", Code: cashu.MeltQuoteErrCode})
		return
	}
	m.n++
	id := fmt.Sprintf("me%d", m.n)
	m.meltQuotes[id] = &tmMeltQuote{amount: amt, feeReserve: m.feeReserve, state: nut05.Unpaid}
	reply(w, &nut05.PostMeltQuoteBolt11Response{Quote: id, Amount: amt, FeeReserve: m.feeReserve, State: nut05.Unpaid})
}

func (m *testMint) meltQuoteState(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q := m.meltQuotes[r.PathValue("id")]
	if q == nil {
		refuse(w, cashu.QuoteNotExistErr)
		return
	}
	reply(w, &nut05.PostMeltQuoteBolt11Response{Quote: r.PathValue("id"), Amount: q.amount, FeeReserve: q.feeReserve, State: q.state, Change: q.change})
}

func (m *testMint) melt(w http.ResponseWriter, r *http.Request) {
	var req nut05.PostMeltBolt11Request
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	q := m.meltQuotes[req.Quote]
	if q == nil {
		refuse(w, cashu.QuoteNotExistErr)
		return
	}
	if q.state != nut05.Unpaid {
		refuse(w, cashu.MeltQuoteAlreadyPaid)
		return
	}
	ys, cerr := m.verifyInputsLocked(req.Inputs)
	if cerr != nil {
		refuse(w, *cerr)
		return
	}
	if req.Inputs.Amount() < q.amount+q.feeReserve+m.feeLocked(req.Inputs) {
		refuse(w, cashu.InsufficientProofsAmount)
		return
	}
	q.inputs, q.outputs = req.Inputs, req.Outputs
	if m.meltFail {
		m.settleLocked(q, false)
		reply(w, &nut05.PostMeltQuoteBolt11Response{Quote: req.Quote, Amount: q.amount, FeeReserve: q.feeReserve, State: q.state})
		return
	}
	if m.meltPending {
		for _, y := range ys {
			m.pending[y] = true
		}
		q.state = nut05.Pending
		reply(w, &nut05.PostMeltQuoteBolt11Response{Quote: req.Quote, Amount: q.amount, FeeReserve: q.feeReserve, State: q.state})
		return
	}
	m.settleLocked(q, true)
	reply(w, &nut05.PostMeltQuoteBolt11Response{Quote: req.Quote, Amount: q.amount, FeeReserve: q.feeReserve, State: q.state, Preimage: "00ff", Change: q.change})
}

// settleMelt ends a pending melt as paid or failed.
func (m *testMint) settleMelt(id string, paid bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.settleLocked(m.meltQuotes[id], paid)
}

func (m *testMint) settleLocked(q *tmMeltQuote, paid bool) {
	for _, p := range q.inputs {
		y, _ := proofY(p.Secret)
		delete(m.pending, y)
		if paid {
			m.spent[y] = true
		}
	}
	if !paid {
		q.state = nut05.Unpaid
		return
	}
	q.state = nut05.Paid
	change := q.inputs.Amount() - q.amount - m.actualFee - m.feeLocked(q.inputs)
	amounts := cashu.AmountSplit(change)
	if len(amounts) > len(q.outputs) {
		m.t.Errorf("test mint: %d change amounts but %d blank outputs", len(amounts), len(q.outputs))
		return
	}
	outs := make(cashu.BlindedMessages, len(amounts))
	for i, a := range amounts {
		outs[i] = q.outputs[i]
		outs[i].Amount = a
	}
	sigs, cerr := m.signLocked(outs)
	if cerr != nil {
		m.t.Errorf("test mint: change: %v", cerr)
		return
	}
	q.change = sigs
}

func (m *testMint) checkstate(w http.ResponseWriter, r *http.Request) {
	var req nut07.PostCheckStateRequest
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var out nut07.PostCheckStateResponse
	for _, y := range req.Ys {
		st := nut07.Unspent
		if m.spent[y] {
			st = nut07.Spent
		} else if m.pending[y] {
			st = nut07.Pending
		}
		out.States = append(out.States, nut07.ProofState{Y: y, State: st})
	}
	reply(w, &out)
}

func (m *testMint) restore(w http.ResponseWriter, r *http.Request) {
	if m.noRestore {
		refuse(w, cashu.Error{Detail: "restore not supported", Code: cashu.StandardErrCode})
		return
	}
	var req nut09.PostRestoreRequest
	if !decode(r, &req) {
		refuse(w, cashu.StandardErr)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var out nut09.PostRestoreResponse
	for _, o := range req.Outputs {
		if sig, ok := m.signed[o.B_]; ok {
			out.Outputs = append(out.Outputs, m.signedOut[o.B_])
			out.Signatures = append(out.Signatures, sig)
		}
	}
	reply(w, out)
}

func (m *testMint) feeLocked(ps cashu.Proofs) uint64 {
	return (uint64(len(ps))*uint64(m.ks.InputFeePpk) + 999) / 1000
}

// verifyInputsLocked checks each proof's signature, spent/pending state, and
// NUT-11 P2PK witness. It returns the proofs' Ys.
func (m *testMint) verifyInputsLocked(ps cashu.Proofs) ([]string, *cashu.Error) {
	if len(ps) == 0 {
		return nil, &cashu.NoProofsProvided
	}
	seen := map[string]bool{}
	var ys []string
	for _, p := range ps {
		if p.Id != m.ks.Id {
			return nil, &cashu.UnknownKeysetErr
		}
		kp, ok := m.ks.Keys[p.Amount]
		if !ok {
			return nil, &cashu.InvalidProofErr
		}
		cb, err := hex.DecodeString(p.C)
		if err != nil {
			return nil, &cashu.InvalidProofErr
		}
		C, err := secp256k1.ParsePubKey(cb)
		if err != nil || !crypto.Verify(p.Secret, kp.PrivateKey, C) {
			return nil, &cashu.InvalidProofErr
		}
		y, _ := proofY(p.Secret)
		if seen[y] {
			return nil, &cashu.DuplicateProofs
		}
		seen[y] = true
		if m.spent[y] {
			return nil, &cashu.ProofAlreadyUsedErr
		}
		if m.pending[y] {
			return nil, &cashu.ProofPendingErr
		}
		if secret, err := nut10.DeserializeSecret(p.Secret); err == nil && secret.Kind == nut10.P2PK {
			pk, err := nut11.ParsePublicKey(secret.Data.Data)
			if err != nil {
				return nil, &nut11.InvalidWitness
			}
			var wit nut11.P2PKWitness
			if json.Unmarshal([]byte(p.Witness), &wit) != nil || len(wit.Signatures) == 0 {
				return nil, &nut11.NoSignaturesErr
			}
			h := sha256.Sum256([]byte(p.Secret))
			if !nut11.HasValidSignatures(h[:], wit.Signatures, 1, []*secp256k1.PublicKey{pk}) {
				return nil, &nut11.NotEnoughSignaturesErr
			}
		}
		ys = append(ys, y)
	}
	return ys, nil
}

func (m *testMint) signLocked(outs cashu.BlindedMessages) (cashu.BlindedSignatures, *cashu.Error) {
	sigs := make(cashu.BlindedSignatures, len(outs))
	for i, o := range outs {
		if o.Id != m.ks.Id {
			return nil, &cashu.UnknownKeysetErr
		}
		kp, ok := m.ks.Keys[o.Amount]
		if !ok {
			return nil, &cashu.InvalidBlindedMessageAmount
		}
		if _, dup := m.signed[o.B_]; dup {
			return nil, &cashu.BlindedMessageAlreadySigned
		}
		bb, err := hex.DecodeString(o.B_)
		if err != nil {
			return nil, &cashu.StandardErr
		}
		B, err := secp256k1.ParsePubKey(bb)
		if err != nil {
			return nil, &cashu.StandardErr
		}
		C_ := crypto.SignBlindedMessage(B, kp.PrivateKey)
		e, s := crypto.GenerateDLEQ(kp.PrivateKey, B, C_)
		d := &cashu.DLEQProof{E: hex.EncodeToString(e.Serialize()), S: hex.EncodeToString(s.Serialize())}
		if m.badDLEQ {
			d.S = strings.Repeat("11", 32)
		}
		sigs[i] = cashu.BlindedSignature{Amount: o.Amount, C_: hex.EncodeToString(C_.SerializeCompressed()), Id: o.Id, DLEQ: d}
	}
	for i, o := range outs {
		m.signed[o.B_] = sigs[i]
		m.signedOut[o.B_] = o
	}
	return sigs, nil
}
