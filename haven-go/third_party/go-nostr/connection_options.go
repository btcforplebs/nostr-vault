//go:build !js

package nostr

import (
	"crypto/tls"
	"net"
	"net/http"
	"net/textproto"
	"time"

	ws "github.com/coder/websocket"
)

var defaultConnectionOptions = &ws.DialOptions{
	CompressionMode: ws.CompressionContextTakeover,
	HTTPHeader: http.Header{
		textproto.CanonicalMIMEHeaderKey("User-Agent"): {"github.com/nbd-wtf/go-nostr"},
	},
}

// dialTimeout bounds one TCP connect and one TLS handshake. (HAVEN PATCH)
const dialTimeout = 10 * time.Second

func getConnectionOptions(requestHeader http.Header, tlsConfig *tls.Config) *ws.DialOptions {
	if requestHeader == nil && tlsConfig == nil {
		return defaultConnectionOptions
	}

	return &ws.DialOptions{
		HTTPHeader:      requestHeader,
		CompressionMode: ws.CompressionContextTakeover,
		HTTPClient: &http.Client{
			Transport: &http.Transport{
				TLSClientConfig: tlsConfig,
				// HAVEN PATCH: net/http keeps dialling after the request's
				// context ends (a later request might use the conn), and the
				// zero Dialer has no timeout, so every failed connect to an
				// unreachable relay held a SYN_SENT socket for the kernel's
				// ~127 s. Bound the dial and the handshake, and never pool:
				// this Transport serves one websocket and is then dropped.
				DialContext:         (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext,
				TLSHandshakeTimeout: dialTimeout,
				IdleConnTimeout:     time.Second,
				MaxIdleConns:        1,
			},
		},
	}
}
