package wallet

// The local test mint, served for the Apple wallet tests
// (HavenApp/CashuWalletTests, run by scripts/cashu-swift-test.sh). Skipped
// unless CASHU_SWIFT_HARNESS names the file to write the mint and control
// URLs to. The control server is the fake Lightning side:
//   GET /invoice?amount=N  -> a bolt11 the mint will melt for N sats
//   GET /pay?quote=ID      -> marks a receive (mint) quote paid
//   GET /melt-pending?on=1 -> melts stay PENDING (the "may still pay" case)
//   GET /bad-dleq?on=1     -> signatures carry a wrong DLEQ (bad change -> stuck op)
//   GET /no-restore?on=1   -> /v1/restore refuses (a stuck op stays stuck)
//   POST /sign             -> {sk, kind, created_at, tags, content}: the signed
//                             event, as an app signer would make it
//   POST /nip44            -> {sk, op: encrypt|decrypt, text}: NIP-44 to self
//   GET /keypair           -> {sk, pk}: a throwaway account
//   GET /stop              -> ends the test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/elnosh/gonuts/cashu/nuts/nut04"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip44"
)

func TestSwiftHarnessMint(t *testing.T) {
	out := os.Getenv("CASHU_SWIFT_HARNESS")
	if out == "" {
		t.Skip("CASHU_SWIFT_HARNESS not set")
	}
	m := newTestMint(t, 0)
	stop := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("GET /invoice", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.ParseUint(r.URL.Query().Get("amount"), 10, 64)
		if err != nil || n == 0 {
			http.Error(w, "amount", http.StatusBadRequest)
			return
		}
		fmt.Fprint(w, m.invoice(n))
	})
	mux.HandleFunc("GET /pay", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		q := m.mintQuotes[r.URL.Query().Get("quote")]
		if q != nil {
			q.state = nut04.Paid
		}
		m.mu.Unlock()
		if q == nil {
			http.Error(w, "no such quote", http.StatusNotFound)
		}
	})
	mux.HandleFunc("GET /melt-pending", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.meltPending = r.URL.Query().Get("on") == "1"
		m.mu.Unlock()
	})
	mux.HandleFunc("GET /bad-dleq", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.badDLEQ = r.URL.Query().Get("on") == "1"
		m.mu.Unlock()
	})
	mux.HandleFunc("GET /no-restore", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		m.noRestore = r.URL.Query().Get("on") == "1"
		m.mu.Unlock()
	})
	// The Swift tests' signer (CashuVaultSyncTests): a throwaway account
	// key signs and NIP-44-encrypts to itself, the way the app's signers do.
	mux.HandleFunc("POST /sign", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			SK        string     `json:"sk"`
			Kind      int        `json:"kind"`
			CreatedAt int64      `json:"created_at"`
			Tags      nostr.Tags `json:"tags"`
			Content   string     `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if in.Tags == nil {
			in.Tags = nostr.Tags{}
		}
		ev := nostr.Event{Kind: in.Kind, CreatedAt: nostr.Timestamp(in.CreatedAt), Tags: in.Tags, Content: in.Content}
		if err := ev.Sign(in.SK); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(ev)
	})
	mux.HandleFunc("POST /nip44", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ SK, Op, Text string }
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		pk, err := nostr.GetPublicKey(in.SK)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		ck, err := nip44.GenerateConversationKey(pk, in.SK)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var out string
		if in.Op == "encrypt" {
			out, err = nip44.Encrypt(in.Text, ck)
		} else {
			out, err = nip44.Decrypt(in.Text, ck)
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		fmt.Fprint(w, out)
	})
	mux.HandleFunc("GET /keypair", func(w http.ResponseWriter, r *http.Request) {
		sk := nostr.GeneratePrivateKey()
		pk, _ := nostr.GetPublicKey(sk)
		_ = json.NewEncoder(w).Encode(map[string]string{"sk": sk, "pk": pk})
	})
	mux.HandleFunc("GET /stop", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-stop:
		default:
			close(stop)
		}
	})
	ctl := httptest.NewServer(mux)
	defer ctl.Close()
	b, _ := json.Marshal(map[string]string{"mint": m.URL(), "control": ctl.URL})
	if err := os.WriteFile(out, b, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stop:
	case <-time.After(10 * time.Minute):
		t.Fatal("harness never told to stop")
	}
}
