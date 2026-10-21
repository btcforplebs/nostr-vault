package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Photos through the Mac (Logen, 2026-10-21): a phone with no media server of
// its own uploads a photo to the owner's Mac over the mesh and asks the Mac to
// pass it on to the owner's public Blossom server, which the note links. The
// phone signs that server's upload token itself and sends it along; the Mac
// only carries it, so the Mac needs no key and can only ever put that one blob
// on that one server.
//
//	X-Forward-To:            https://<public blossom server>
//	X-Forward-Authorization: Nostr <kind 24242, t=upload, x=<sha256>>
const (
	forwardToHeader   = "X-Forward-To"
	forwardAuthHeader = "X-Forward-Authorization"
)

// blobForward is one validated request to pass a blob on.
type blobForward struct {
	target    string // https://host[/path], no trailing slash
	sha256    string
	authB64     string // padded standard base64, as khatru-style servers expect
	contentType string
	expiresAt   time.Time
}

// parseBlobForward reads the forward headers of an upload. nil, nil when
// there are none. The token must be one the owner signed for exactly this
// upload: the Mac would otherwise carry anyone's blob to anywhere.
func parseBlobForward(r *http.Request, now time.Time) (*blobForward, error) {
	target := strings.TrimSpace(r.Header.Get(forwardToHeader))
	authHeader := strings.TrimSpace(r.Header.Get(forwardAuthHeader))
	if target == "" && authHeader == "" {
		return nil, nil
	}
	if r.Method != http.MethodPut || r.URL.Path != "/upload" {
		return nil, errors.New("forward is only for PUT /upload")
	}
	u, err := url.Parse(target)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("forward target must be a plain https URL")
	}
	if forwardHostRefused(u.Hostname()) {
		return nil, errors.New("forward target is not a public host")
	}
	if !strings.HasPrefix(authHeader, "Nostr ") {
		return nil, errors.New("forward authorization missing")
	}
	raw, err := decodeNostrAuthToken(authHeader[6:])
	if err != nil {
		return nil, errors.New("forward authorization is not base64")
	}
	var ev nostr.Event
	if err := json.Unmarshal(raw, &ev); err != nil {
		return nil, errors.New("forward authorization is not an event")
	}
	if ev.Kind != 24242 {
		return nil, errors.New("forward authorization is not kind 24242")
	}
	if ok, _ := ev.CheckSignature(); !ok {
		return nil, errors.New("forward authorization signature is invalid")
	}
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return nil, errors.New("forward authorization is not from a key this relay serves")
	}
	if t := ev.Tags.GetFirst([]string{"t"}); t == nil || len(*t) < 2 || (*t)[1] != "upload" {
		return nil, errors.New("forward authorization is not for an upload")
	}
	x := ev.Tags.GetFirst([]string{"x"})
	if x == nil || len(*x) < 2 || len((*x)[1]) != 64 {
		return nil, errors.New("forward authorization names no blob")
	}
	exp := ev.Tags.GetFirst([]string{"expiration"})
	if exp == nil || len(*exp) < 2 {
		return nil, errors.New("forward authorization has no expiration")
	}
	secs, err := strconv.ParseInt((*exp)[1], 10, 64)
	if err != nil || time.Unix(secs, 0).Before(now) {
		return nil, errors.New("forward authorization has expired")
	}
	// The header may say X-SHA-256; the token is what the public server checks.
	if h := r.Header.Get("X-SHA-256"); h != "" && !strings.EqualFold(h, (*x)[1]) {
		return nil, errors.New("forward authorization is for another blob")
	}
	return &blobForward{
		target:    strings.TrimRight(u.String(), "/"),
		sha256:    strings.ToLower((*x)[1]),
		authB64:     base64Std(raw),
		contentType: r.Header.Get("Content-Type"),
		expiresAt:   time.Unix(secs, 0),
	}, nil
}

// forwardHostIsPrivate: loopback, LAN, link-local, CGNAT/Tailscale and .local
// names are never forward targets. Names are checked again at dial time
// (forwardDialControl), since a public name can resolve to a private address.
func forwardHostIsPrivate(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || strings.HasSuffix(h, ".local") ||
		strings.HasSuffix(h, ".fips") || strings.HasSuffix(h, ".ts.net") || !strings.Contains(h, ".") && net.ParseIP(h) == nil {
		return true
	}
	if ip := net.ParseIP(h); ip != nil {
		return forwardIPIsPrivate(ip)
	}
	return false
}

// forwardHostRefused is forwardHostIsPrivate; tests serve on loopback.
var forwardHostRefused = forwardHostIsPrivate

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

func forwardIPIsPrivate(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || cgnat.Contains(ip)
}

// forwardDialControl refuses a connection to a private address, whatever name
// led there.
func forwardDialControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip == nil || forwardIPIsPrivate(ip) {
		return fmt.Errorf("refusing to forward to %s", host)
	}
	return nil
}

// forwardClient is replaced in tests (which serve on loopback).
var forwardClient = &http.Client{
	Timeout: 10 * time.Minute,
	Transport: &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second, Control: forwardDialControl}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second,
	},
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// forwardBackoff is the wait before each retry. The token's expiration ends
// the retries sooner; the phone's own retry of the public upload covers a Mac
// that restarts before it gets through.
var forwardBackoff = []time.Duration{30 * time.Second, 2 * time.Minute, 10 * time.Minute, 30 * time.Minute, time.Hour}

// forwardOnce PUTs the stored blob to the target. done=true on success or on
// an answer that retrying cannot change.
func forwardOnce(ctx context.Context, f *blobForward) (done bool, err error) {
	file, err := openBlobFile(f.sha256, "")
	if err != nil {
		return true, fmt.Errorf("blob not stored here: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, f.target+"/upload", file)
	if err != nil {
		return true, err
	}
	req.ContentLength = info.Size()
	req.Header.Set("Authorization", "Nostr "+f.authB64)
	req.Header.Set("X-SHA-256", f.sha256)
	ct := f.contentType
	if ct == "" {
		ct = "application/octet-stream"
	}
	req.Header.Set("Content-Type", ct)
	resp, err := forwardClient.Do(req)
	if err != nil {
		return false, err
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return true, nil
	case resp.StatusCode == 408 || resp.StatusCode == 429 || resp.StatusCode >= 500:
		return false, fmt.Errorf("HTTP %d", resp.StatusCode)
	default:
		return true, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
}

// runBlobForward retries until the blob is on the target, the answer is
// final, or the token expires.
func runBlobForward(ctx context.Context, f *blobForward, now func() time.Time, sleep func(context.Context, time.Duration) bool) error {
	for attempt := 0; ; attempt++ {
		done, err := forwardOnce(ctx, f)
		if done {
			return err
		}
		if attempt >= len(forwardBackoff) || now().Add(forwardBackoff[attempt]).After(f.expiresAt) {
			return fmt.Errorf("gave up: %w", err)
		}
		slog.Info("blob forward will retry", "sha256", f.sha256[:8], "target", f.target, "err", err)
		if !sleep(ctx, forwardBackoff[attempt]) {
			return ctx.Err()
		}
	}
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// statusRecorder keeps the status an inner handler wrote.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// serveWithForward runs the upload, then passes the blob on once this relay
// has stored it. A bad forward request is refused before the upload, so the
// phone learns at once instead of trusting a link nothing will fill.
func serveWithForward(w http.ResponseWriter, r *http.Request, next http.Handler) {
	fwd, err := parseBlobForward(r, time.Now())
	if err != nil {
		http.Error(w, "forward: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.Header.Del(forwardToHeader)
	r.Header.Del(forwardAuthHeader)
	if fwd == nil {
		next.ServeHTTP(w, r)
		return
	}
	rec := &statusRecorder{ResponseWriter: w}
	next.ServeHTTP(rec, r)
	if rec.status < 200 || rec.status >= 300 {
		return
	}
	go func() {
		ctx, cancel := context.WithDeadline(context.Background(), fwd.expiresAt)
		defer cancel()
		if err := runBlobForward(ctx, fwd, time.Now, sleepCtx); err != nil {
			slog.Warn("blob forward failed", "sha256", fwd.sha256[:8], "target", fwd.target, "err", err)
			return
		}
		slog.Info("blob forwarded", "sha256", fwd.sha256[:8], "target", fwd.target)
	}()
}
