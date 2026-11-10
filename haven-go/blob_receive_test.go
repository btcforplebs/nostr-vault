package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// The relay port listens on the LAN on the Mac. Whose key signed an upload or
// a mirror is decided from the header, before a body byte is read or a URL
// fetched, and no blob passes maxBlobBytes.

func httpBase(h *havenUnderTest) string { return "http" + strings.TrimPrefix(h.base, "ws") }

// headersOnly sends a PUT /upload's headers and no body, and returns the
// status line and X-Reason the server answers with.
func headersOnly(t *testing.T, h *havenUnderTest, auth string, length int64) (string, string) {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(httpBase(h), "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "PUT /upload HTTP/1.1\r\nHost: x\r\nAuthorization: %s\r\nContent-Type: video/mp4\r\nContent-Length: %d\r\n\r\n", auth, length)
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("no answer before the body was sent: %v", err)
	}
	resp.Body.Close()
	return resp.Status, resp.Header.Get("X-Reason")
}

func TestUploadStrangerRefusedBeforeBody(t *testing.T) {
	h := startHaven(t)
	auth := blossomUploadAuth(t, nostr.GeneratePrivateKey(), []byte("x"))
	status, _ := headersOnly(t, h, auth, 200<<20)
	if !strings.HasPrefix(status, "403") {
		t.Fatalf("stranger upload: %q, want 403 before any body", status)
	}
}

func TestUploadOverCapRefusedBeforeBody(t *testing.T) {
	h := startHaven(t)
	auth := blossomUploadAuth(t, h.ownerSK, []byte("x"))
	status, reason := headersOnly(t, h, auth, maxBlobBytes+1)
	if !strings.HasPrefix(status, "413") {
		t.Fatalf("owner upload over the cap: %q, want 413", status)
	}
	if reason != "this vault takes files up to 256 MB" {
		t.Fatalf("X-Reason %q", reason)
	}
}

func TestUploadOwnerStored(t *testing.T) {
	h := startHaven(t)
	body := bytes.Repeat([]byte("o"), 3<<20)
	req, _ := http.NewRequest(http.MethodPut, httpBase(h)+"/upload", bytes.NewReader(body))
	req.Header.Set("Authorization", blossomUploadAuth(t, h.ownerSK, body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("owner upload: %d %s", resp.StatusCode, resp.Header.Get("X-Reason"))
	}
	sum := sha256.Sum256(body)
	if got, err := afero.ReadFile(fs, config.BlossomPath+hex.EncodeToString(sum[:])); err != nil || !bytes.Equal(got, body) {
		t.Fatalf("stored blob: %d bytes, %v", len(got), err)
	}
	if left, _ := afero.Glob(fs, config.BlossomPath+"*.tmp"); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

func mirrorAuth(t *testing.T, sk string, body []byte) string {
	t.Helper()
	sum := sha256.Sum256(body)
	ev := nostr.Event{
		Kind:      24242,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"t", "upload"},
			{"x", hex.EncodeToString(sum[:])},
			{"expiration", fmt.Sprint(time.Now().Add(10 * time.Minute).Unix())},
		},
	}
	if err := ev.Sign(sk); err != nil {
		t.Fatal(err)
	}
	j, _ := json.Marshal(ev)
	return "Nostr " + base64.StdEncoding.EncodeToString(j)
}

// blobSource serves body, counting fetches; chunked hides its length.
func blobSource(t *testing.T, body []byte, chunked bool) (string, *atomic.Int32) {
	var hits atomic.Int32
	src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/octet-stream")
		if chunked {
			w.Write(body[:1])
			w.(http.Flusher).Flush()
			w.Write(body[1:])
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	}))
	t.Cleanup(src.Close)
	return src.URL + "/blob", &hits
}

func mirror(t *testing.T, h *havenUnderTest, auth, url string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPut, httpBase(h)+"/mirror", strings.NewReader(`{"url":"`+url+`"}`))
	req.Header.Set("Authorization", auth)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode, resp.Header.Get("X-Reason")
}

func TestMirrorStrangerNeverFetches(t *testing.T) {
	h := startHaven(t)
	body := []byte("a blob somewhere else")
	url, hits := blobSource(t, body, false)
	if code, _ := mirror(t, h, mirrorAuth(t, nostr.GeneratePrivateKey(), body), url); code != http.StatusForbidden {
		t.Fatalf("stranger mirror: %d, want 403", code)
	}
	if n := hits.Load(); n != 0 {
		t.Fatalf("stranger mirror fetched the URL %d times", n)
	}
}

func TestMirrorOwnerStored(t *testing.T) {
	h := startHaven(t)
	body := bytes.Repeat([]byte("m"), 2<<20)
	url, _ := blobSource(t, body, false)
	if code, why := mirror(t, h, mirrorAuth(t, h.ownerSK, body), url); code != http.StatusOK {
		t.Fatalf("owner mirror: %d %s", code, why)
	}
	sum := sha256.Sum256(body)
	if got, err := afero.ReadFile(fs, config.BlossomPath+hex.EncodeToString(sum[:])); err != nil || !bytes.Equal(got, body) {
		t.Fatalf("mirrored blob: %d bytes, %v", len(got), err)
	}
}

// Over the cap, with or without a declared length: 413, nothing kept.
func TestMirrorOverCap(t *testing.T) {
	for _, chunked := range []bool{false, true} {
		t.Run(fmt.Sprint("chunked=", chunked), func(t *testing.T) {
			h := startHaven(t)
			blossomServer.MaxUploadSize = 1 << 20
			body := bytes.Repeat([]byte("b"), 2<<20)
			url, _ := blobSource(t, body, chunked)
			code, why := mirror(t, h, mirrorAuth(t, h.ownerSK, body), url)
			if code != http.StatusRequestEntityTooLarge || why != "this vault takes files up to 1 MB" {
				t.Fatalf("mirror over the cap: %d %q", code, why)
			}
			if left, _ := afero.Glob(fs, config.BlossomPath+"*"); len(left) != 0 {
				t.Fatalf("files left: %v", left)
			}
		})
	}
}

// A token signed for one blob cannot mirror another.
func TestMirrorWrongBlob(t *testing.T) {
	h := startHaven(t)
	body := []byte("the real bytes")
	url, _ := blobSource(t, body, false)
	if code, _ := mirror(t, h, mirrorAuth(t, h.ownerSK, []byte("other bytes")), url); code != http.StatusForbidden {
		t.Fatalf("mirror of another blob: %d, want 403", code)
	}
	if left, _ := afero.Glob(fs, config.BlossomPath+"*"); len(left) != 0 {
		t.Fatalf("files left: %v", left)
	}
}
