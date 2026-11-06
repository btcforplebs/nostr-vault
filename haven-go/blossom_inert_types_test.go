//go:build !(js && wasm)

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// The extension in a blob URL is the requester's choice: no stored file may
// come back as a page or script on the vault's origin (Tron, PR #1798 review:
// an owner-imported HTML file was served as text/html at /<sha>.html).
func TestBlobsAreNeverServedAsActiveTypes(t *testing.T) {
	owner, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	openCopyVault(t, owner)
	prevFs, prevRelay := fs, outboxRelay
	t.Cleanup(func() { fs, outboxRelay = prevFs, prevRelay })
	fs = afero.NewOsFs()
	outboxRelay = khatru.NewRelay()
	bs := blossom.New(outboxRelay, "http://localhost")
	bs.Store = blossom.EventStoreBlobIndexWrapper{Store: blossomDB, ServiceURL: bs.ServiceURL}
	bs.LoadBlob = append(bs.LoadBlob, loadBlob)

	page := []byte("<!doctype html><html><script>alert(1)</script></html>")
	pagePath, pageSha := ownerBlobFile(t, page)
	if err := importOwnerBlob(context.Background(), pagePath, pageSha, "image/png"); err != nil {
		t.Fatal(err)
	}
	png := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 64)...)
	pngPath, pngSha := ownerBlobFile(t, png)
	if err := importOwnerBlob(context.Background(), pngPath, pngSha, "image/png"); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(dynamicRelayHandler))
	defer srv.Close()
	get := func(path string) (string, string, int) {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.Header.Get("Content-Type"), resp.Header.Get("X-Content-Type-Options"), resp.StatusCode
	}
	for _, ext := range []string{".html", ".htm", ".HTML", ".svg", ".xhtml", ".xml", ".js", ".mjs", ""} {
		ct, nosniff, code := get("/" + pageSha + ext)
		if code != http.StatusOK {
			t.Fatalf("GET %s: status %d", ext, code)
		}
		if ct != "application/octet-stream" || nosniff != "nosniff" {
			t.Errorf("GET /<sha>%s: Content-Type %q, X-Content-Type-Options %q", ext, ct, nosniff)
		}
	}
	// Media is still media.
	for ext, want := range map[string]string{".png": "image/png", "": "image/png"} {
		if ct, nosniff, _ := get("/" + pngSha + ext); ct != want || nosniff != "nosniff" {
			t.Errorf("GET png%s: Content-Type %q (want %q), nosniff %q", ext, ct, want, nosniff)
		}
	}

	// A record typed text/html over bytes that sniff as plain text (the
	// signed upload keeps the uploader's Content-Type). Left without a
	// Content-Type, ServeContent took it from the stored type's extension
	// and served a page (Tron, PR #1799 review).
	keep := func(body []byte, typ string) string {
		_, sha := ownerBlobFile(t, body)
		if err := afero.WriteFile(afero.NewOsFs(), config.BlossomPath+sha, body, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := bs.Store.Keep(context.Background(), blossom.BlobDescriptor{SHA256: sha, Type: typ, Size: len(body), Uploaded: nostr.Now()}, owner); err != nil {
			t.Fatal(err)
		}
		return sha
	}
	plainSha := keep([]byte("hello <script>alert(document.domain)</script>"), "text/html")
	for _, ext := range []string{"", ".foo", ".html", ".txt"} {
		if ct, nosniff, _ := get("/" + plainSha + ext); strings.Contains(ct, "html") || ct == "" || nosniff != "nosniff" {
			t.Errorf("GET text/html record%s: Content-Type %q, nosniff %q", ext, ct, nosniff)
		}
	}
	// Bytes the sniffer can't name keep their (inert) stored type.
	mp3Sha := keep(append([]byte{0xff, 0xfb, 0x90, 0x44, 0x00}, make([]byte, 64)...), "audio/mpeg")
	for _, ext := range []string{"", ".foo"} {
		if ct, _, _ := get("/" + mp3Sha + ext); ct != "audio/mpeg" {
			t.Errorf("GET audio/mpeg record%s: Content-Type %q", ext, ct)
		}
	}
}

func TestInertBlobType(t *testing.T) {
	for ct, want := range map[string]string{
		"text/html; charset=utf-8": "application/octet-stream", "image/svg+xml": "application/octet-stream", "text/javascript": "application/octet-stream",
		"application/javascript": "application/octet-stream", "text/xml; charset=utf-8": "application/octet-stream", "application/xhtml+xml": "application/octet-stream",
		"application/atom+xml": "application/octet-stream", "": "application/octet-stream",
		"image/jpeg": "image/jpeg", "video/mp4": "video/mp4", "text/plain; charset=utf-8": "text/plain; charset=utf-8",
	} {
		if got := inertBlobType(ct); got != want {
			t.Errorf("inertBlobType(%q) = %q, want %q", ct, got, want)
		}
	}
}

// Import writes through its own temp file: a shared <sha>.tmp left by another
// writer is neither used nor renamed into place, and nothing .tmp is left.
func TestImportOwnerBlobUsesItsOwnTempFile(t *testing.T) {
	owner, _ := nostr.GetPublicKey(nostr.GeneratePrivateKey())
	openCopyVault(t, owner)
	data := []byte("whole file")
	path, sha := ownerBlobFile(t, data)
	shared := config.BlossomPath + sha + ".tmp"
	if err := afero.WriteFile(afero.NewOsFs(), shared, []byte("half"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := importOwnerBlob(context.Background(), path, sha, "image/jpeg"); err != nil {
		t.Fatal(err)
	}
	got, _ := afero.ReadFile(afero.NewOsFs(), copyBlobFile(sha))
	if string(got) != "whole file" {
		t.Fatalf("stored %q", got)
	}
	if half, _ := afero.ReadFile(afero.NewOsFs(), shared); string(half) != "half" {
		t.Fatalf("another writer's <sha>.tmp was touched: %q", half)
	}
	left, _ := afero.Glob(afero.NewOsFs(), config.BlossomPath+sha+".*.tmp")
	if len(left) != 0 {
		t.Fatalf("temp files left behind: %v", left)
	}
}
