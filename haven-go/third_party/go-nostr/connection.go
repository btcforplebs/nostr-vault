package nostr

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	ws "github.com/coder/websocket"
)

// Connection represents a websocket connection to a Nostr relay.
type Connection struct {
	conn *ws.Conn
}

// HandshakeStatusError is a websocket upgrade the relay answered with a non-101
// HTTP status. (HAVEN PATCH)
type HandshakeStatusError struct {
	StatusCode int
	Err        error
}

func (e *HandshakeStatusError) Error() string { return e.Err.Error() }
func (e *HandshakeStatusError) Unwrap() error { return e.Err }

// NewConnection creates a new websocket connection to a Nostr relay.
func NewConnection(ctx context.Context, url string, requestHeader http.Header, tlsConfig *tls.Config) (*Connection, error) {
	c, resp, err := ws.Dial(ctx, url, getConnectionOptions(requestHeader, tlsConfig))
	if err != nil {
		// HAVEN PATCH: keep the HTTP status of a refused upgrade (429, 403,
		// 503) so callers can tell "the relay said no" from "no network".
		if resp != nil && resp.StatusCode != 0 && resp.StatusCode != http.StatusSwitchingProtocols {
			return nil, &HandshakeStatusError{StatusCode: resp.StatusCode, Err: err}
		}
		return nil, err
	}

	c.SetReadLimit(2 << 24) // 33MB

	return &Connection{
		conn: c,
	}, nil
}

// WriteMessage writes arbitrary bytes to the websocket connection.
func (c *Connection) WriteMessage(ctx context.Context, data []byte) error {
	if err := c.conn.Write(ctx, ws.MessageText, data); err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}

	return nil
}

// ReadMessage reads arbitrary bytes from the websocket connection into the provided buffer.
func (c *Connection) ReadMessage(ctx context.Context, buf io.Writer) error {
	_, reader, err := c.conn.Reader(ctx)
	if err != nil {
		return fmt.Errorf("failed to get reader: %w", err)
	}
	if _, err := io.Copy(buf, reader); err != nil {
		return fmt.Errorf("failed to read message: %w", err)
	}
	return nil
}

// Close closes the websocket connection.
func (c *Connection) Close() error {
	return c.conn.Close(ws.StatusNormalClosure, "")
}

// Ping sends a ping message to the websocket connection.
func (c *Connection) Ping(ctx context.Context) error {
	ctx, cancel := context.WithTimeoutCause(ctx, time.Millisecond*10000, errors.New("ping took too long"))
	defer cancel()
	return c.conn.Ping(ctx)
}
