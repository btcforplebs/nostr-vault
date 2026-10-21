package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/nbd-wtf/go-nostr"
)

// policyClient is a minimal NIP-01/NIP-42/NIP-45 client for the route/policy
// suite. go-nostr's own client dials through coder/websocket, which on
// js/wasm hands the URL to the host's WebSocket API and can never reach a
// relay served inside the same Go process. This one dials with Go's net
// package on every build (real loopback natively, the in-process loopback
// on js/wasm), so the suite runs the same client code in both builds.
type policyClient struct {
	url  string
	conn *websocket.Conn

	writeMu sync.Mutex

	mu        sync.Mutex
	challenge string
	oks       map[string]chan nostr.OKEnvelope
	subs      map[string]*policySub
	counts    map[string]chan policyCountResult
	nextSub   int
}

type policySub struct {
	events chan *nostr.Event
	eose   chan struct{}
	closed chan string
}

type policyCountResult struct {
	n      int64
	closed string
}

func dialPolicyClient(t *testing.T, url string) *policyClient {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	c := &policyClient{
		url:    url,
		conn:   conn,
		oks:    map[string]chan nostr.OKEnvelope{},
		subs:   map[string]*policySub{},
		counts: map[string]chan policyCountResult{},
	}
	go c.readLoop()
	t.Cleanup(func() { conn.Close() })
	return c
}

func (c *policyClient) readLoop() {
	for {
		_, msg, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		switch env := nostr.ParseMessage(string(msg)).(type) {
		case *nostr.AuthEnvelope:
			if env.Challenge != nil {
				c.mu.Lock()
				c.challenge = *env.Challenge
				c.mu.Unlock()
			}
		case *nostr.OKEnvelope:
			c.mu.Lock()
			ch := c.oks[env.EventID]
			delete(c.oks, env.EventID)
			c.mu.Unlock()
			if ch != nil {
				ch <- *env
			}
		case *nostr.EventEnvelope:
			if env.SubscriptionID == nil {
				continue
			}
			if s := c.sub(*env.SubscriptionID); s != nil {
				ev := env.Event
				s.events <- &ev
			}
		case *nostr.EOSEEnvelope:
			if s := c.sub(string(*env)); s != nil {
				close(s.eose)
			}
		case *nostr.ClosedEnvelope:
			if s := c.sub(env.SubscriptionID); s != nil {
				s.closed <- env.Reason
			}
			c.mu.Lock()
			ch := c.counts[env.SubscriptionID]
			delete(c.counts, env.SubscriptionID)
			c.mu.Unlock()
			if ch != nil {
				ch <- policyCountResult{closed: env.Reason}
			}
		case *nostr.CountEnvelope:
			c.mu.Lock()
			ch := c.counts[env.SubscriptionID]
			delete(c.counts, env.SubscriptionID)
			c.mu.Unlock()
			if ch != nil && env.Count != nil {
				ch <- policyCountResult{n: *env.Count}
			}
		}
	}
}

func (c *policyClient) sub(id string) *policySub {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.subs[id]
}

func (c *policyClient) send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

func (c *policyClient) awaitOK(ctx context.Context, id string, env any) error {
	ch := make(chan nostr.OKEnvelope, 1)
	c.mu.Lock()
	c.oks[id] = ch
	c.mu.Unlock()
	if err := c.send(env); err != nil {
		return err
	}
	select {
	case ok := <-ch:
		if !ok.OK {
			return fmt.Errorf("msg: %s", ok.Reason)
		}
		return nil
	case <-ctx.Done():
		return fmt.Errorf("no OK for %s: %w", id, ctx.Err())
	}
}

// Publish sends EVENT and returns the relay's OK; a rejection comes back as
// an error carrying the relay's reason, like go-nostr's Publish.
func (c *policyClient) Publish(ctx context.Context, ev nostr.Event) error {
	return c.awaitOK(ctx, ev.ID, nostr.EventEnvelope{Event: ev})
}

var errNoChallenge = errors.New("no AUTH challenge received yet")

// Auth answers the relay's NIP-42 challenge, signed by sign.
func (c *policyClient) Auth(ctx context.Context, sign func(*nostr.Event) error) error {
	c.mu.Lock()
	challenge := c.challenge
	c.mu.Unlock()
	if challenge == "" {
		return errNoChallenge
	}
	ev := nostr.Event{
		CreatedAt: nostr.Now(),
		Kind:      nostr.KindClientAuthentication,
		Tags:      nostr.Tags{{"relay", c.url}, {"challenge", challenge}},
	}
	if err := sign(&ev); err != nil {
		return err
	}
	return c.awaitOK(ctx, ev.ID, nostr.AuthEnvelope{Event: ev})
}

// Subscribe opens a REQ and returns its channels; it stays open until the
// test's connection closes.
func (c *policyClient) Subscribe(f nostr.Filter) (*policySub, error) {
	c.mu.Lock()
	c.nextSub++
	id := fmt.Sprintf("p%d", c.nextSub)
	s := &policySub{events: make(chan *nostr.Event, 64), eose: make(chan struct{}), closed: make(chan string, 1)}
	c.subs[id] = s
	c.mu.Unlock()
	return s, c.send(nostr.ReqEnvelope{SubscriptionID: id, Filters: nostr.Filters{f}})
}

// Count sends a NIP-45 COUNT. closed is the CLOSED reason when refused.
func (c *policyClient) Count(ctx context.Context, f nostr.Filter) (n int64, closed string, err error) {
	c.mu.Lock()
	c.nextSub++
	id := fmt.Sprintf("c%d", c.nextSub)
	ch := make(chan policyCountResult, 1)
	c.counts[id] = ch
	c.mu.Unlock()
	if err := c.send(nostr.CountEnvelope{SubscriptionID: id, Filter: f}); err != nil {
		return 0, "", err
	}
	select {
	case r := <-ch:
		return r.n, r.closed, nil
	case <-ctx.Done():
		return 0, "", ctx.Err()
	}
}

// policyReq runs one REQ to EOSE or CLOSED and returns the events plus the
// CLOSED reason ("" when the subscription reached EOSE).
func policyReq(t *testing.T, c *policyClient, f nostr.Filter) ([]*nostr.Event, string) {
	t.Helper()
	s, err := c.Subscribe(f)
	if err != nil {
		t.Fatal(err)
	}
	var out []*nostr.Event
	timeout := time.After(10 * time.Second)
	for {
		select {
		case ev := <-s.events:
			out = append(out, ev)
		case <-s.eose:
			for {
				select {
				case ev := <-s.events:
					out = append(out, ev)
				default:
					return out, ""
				}
			}
		case reason := <-s.closed:
			return out, reason
		case <-timeout:
			t.Fatalf("REQ %v timed out", f)
		}
	}
}
