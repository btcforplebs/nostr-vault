package main

import (
	"strings"
	"testing"
)

func TestRelayUserAgentNamesTheApp(t *testing.T) {
	ua := relayUserAgent("https://example.invalid/haven")
	t.Logf("Go engine User-Agent: %s", ua)
	if !strings.HasPrefix(ua, "NostrVault/") || !strings.HasSuffix(ua, " (+https://example.invalid/haven)") {
		t.Fatalf("unexpected User-Agent %q", ua)
	}
}
