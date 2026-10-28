package main

import (
	"net/url"
	"strings"
	"testing"
)

// A bunker link that fails to parse is logged without the link: url.Parse's
// error quotes the whole URL, secret included (Android review K4).
func TestBunkerParseErrorDropsTheSecret(t *testing.T) {
	_, err := url.Parse("bunker://abc\x7fdef?relay=wss://r.example&secret=hunter2-bunker-secret")
	if err == nil {
		t.Fatal("expected a parse error")
	}
	if !strings.Contains(err.Error(), "hunter2-bunker-secret") {
		t.Fatal("control: url.Parse's own error should quote the secret")
	}
	if got := bunkerParseError(err).Error(); strings.Contains(got, "hunter2") || strings.Contains(got, "secret=") {
		t.Fatalf("logged error still carries the secret: %q", got)
	}
}
