package wallet

// The local test mint, served for the Apple wallet tests
// (HavenApp/CashuWalletTests, run by scripts/cashu-swift-test.sh). Skipped
// unless CASHU_SWIFT_HARNESS names the file to write the mint and control
// URLs to. The control server is the fake Lightning side:
//   GET /invoice?amount=N  -> a bolt11 the mint will melt for N sats
//   GET /pay?quote=ID      -> marks a receive (mint) quote paid
//   GET /melt-pending?on=1 -> melts stay PENDING (the "may still pay" case)
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
