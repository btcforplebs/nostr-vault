package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/fiatjaf/khatru/policies"
)

// Behind havend every client arrives from 127.0.0.1. The box's private relay
// limiter (3 per 5 min, burst 9) must count each real client, not wave
// everyone through as loopback (Ted's run: 30/30 accepted).
func TestProxiedClientsFaceTheConnectionLimiter(t *testing.T) {
	newLimiter := func() func(*http.Request) bool {
		return bypassLocalhostConnectionLimiter(policies.ConnectionRateLimiter(3, 5*time.Minute, 9))
	}
	viaDoor := func(xff string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/private", nil)
		r.RemoteAddr = "127.0.0.1:41000"
		if xff != "" {
			r.Header.Set("X-Forwarded-For", xff)
		}
		return r
	}
	accepted := func(limited func(*http.Request) bool, n int, mk func() *http.Request) int {
		ok := 0
		for i := 0; i < n; i++ {
			if !limited(mk()) {
				ok++
			}
		}
		return ok
	}

	// Control: read as loopback, the LAN client is never limited.
	if got := accepted(newLimiter(), 30, func() *http.Request { return viaDoor("192.168.1.50") }); got != 30 {
		t.Fatalf("control: %d/30 accepted without the proxy rewrite (the bug is gone?)", got)
	}

	lim := newLimiter()
	if got := accepted(lim, 30, func() *http.Request { return clientFromProxy(viaDoor("192.168.1.50")) }); got != 9 {
		t.Fatalf("LAN client via havend: %d/30 accepted, want the burst of 9", got)
	}
	// Another client has its own bucket.
	if got := accepted(lim, 3, func() *http.Request { return clientFromProxy(viaDoor("192.168.1.51")) }); got != 3 {
		t.Fatalf("second client: %d/3 accepted", got)
	}
	// The box itself (havend asking its vault, no X-Forwarded-For) and a
	// client on the box's own loopback stay unlimited.
	if got := accepted(lim, 30, func() *http.Request { return clientFromProxy(viaDoor("")) }); got != 30 {
		t.Fatalf("havend's own requests: %d/30", got)
	}
	if got := accepted(lim, 30, func() *http.Request { return clientFromProxy(viaDoor("127.0.0.1")) }); got != 30 {
		t.Fatalf("loopback client: %d/30", got)
	}
	// An address that does not parse is limited as unknown, never loopback.
	if got := accepted(lim, 30, func() *http.Request { return clientFromProxy(viaDoor("not-an-ip")) }); got != 9 {
		t.Fatalf("bad X-Forwarded-For: %d/30 accepted", got)
	}
}

func TestClientFromProxyTrustsOnlyTheDoor(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "127.0.0.1:41000"
	r.Header.Add("X-Forwarded-For", "10.0.0.9, 192.168.1.50")
	got := clientFromProxy(r)
	if got.RemoteAddr != "192.168.1.50:0" || got.Header.Get("X-Forwarded-For") != "" {
		t.Fatalf("last entry is the door's: %q xff %q", got.RemoteAddr, got.Header.Get("X-Forwarded-For"))
	}
	if r.RemoteAddr != "127.0.0.1:41000" || r.Header.Get("X-Forwarded-For") == "" {
		t.Fatal("the original request was changed")
	}
	// A peer that is not loopback cannot pick its address.
	r = httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "192.168.1.60:5000"
	r.Header.Set("X-Forwarded-For", "127.0.0.1")
	if got := clientFromProxy(r); got.RemoteAddr != "192.168.1.60:5000" {
		t.Fatalf("spoofed X-Forwarded-For honoured: %q", got.RemoteAddr)
	}
}

// A zoned link-local IPv6 client (as Go reports one on a LAN) is its own
// client, not the shared 0.0.0.0 bucket that unparsable addresses get.
func TestClientFromProxyZonedIPv6(t *testing.T) {
	via := func(xff string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = "127.0.0.1:41000"
		r.Header.Set("X-Forwarded-For", xff)
		return clientFromProxy(r)
	}
	if got := via("fe80::1%eth0").RemoteAddr; got != "[fe80::1]:0" {
		t.Fatalf("zoned client: %q", got)
	}
	if got := via("::ffff:192.168.1.50").RemoteAddr; got != "192.168.1.50:0" {
		t.Fatalf("mapped IPv4: %q", got)
	}
	lim := bypassLocalhostConnectionLimiter(policies.ConnectionRateLimiter(3, 5*time.Minute, 9))
	for i := 0; i < 9; i++ {
		if lim(via("fe80::1%eth0")) {
			t.Fatalf("fe80::1 limited at %d", i)
		}
	}
	if !lim(via("fe80::1%eth0")) {
		t.Fatal("fe80::1 not limited after its burst")
	}
	if lim(via("fe80::2%eth0")) {
		t.Fatal("fe80::2 shares fe80::1's bucket")
	}
	if lim(via("not-an-ip")) {
		t.Fatal("unknown bucket already spent by zoned clients")
	}
}
