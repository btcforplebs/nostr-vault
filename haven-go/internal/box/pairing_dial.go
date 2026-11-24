package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// PairCrypto is what pairing needs the box's mesh key for. havend never
// holds that key (linux/mesh/README.md, "Files and uids"), so MeshDial asks
// nv-mesh over dial.sock (linux/mesh/src/dial.rs pair_open, pair_ack).
type PairCrypto interface {
	// PairOpen checks one kind-21195 event sent to this box and opens its
	// content: the sender's mesh pubkey (hex) and the plaintext.
	PairOpen(ctx context.Context, ev *nostr.Event) (sender, content string, err error)
	// PairAck seals content (a check-words ack, nothing else is accepted)
	// to the device npub and signs it with the box's mesh key.
	PairAck(ctx context.Context, toNpub, content string) (*nostr.Event, error)
}

// PairOpen is dial.sock's pair_open.
func (d MeshDial) PairOpen(ctx context.Context, ev *nostr.Event) (string, string, error) {
	if ev == nil {
		return "", "", errors.New("no event")
	}
	out, err := d.ask(ctx, map[string]any{"op": "pair_open", "event": ev})
	if err != nil {
		return "", "", err
	}
	sender, _ := out["sender"].(string)
	content, _ := out["content"].(string)
	if !isHex64(sender) {
		return "", "", errors.New("nv-mesh gave no sender")
	}
	return sender, content, nil
}

// PairAck is dial.sock's pair_ack.
func (d MeshDial) PairAck(ctx context.Context, toNpub, content string) (*nostr.Event, error) {
	out, err := d.ask(ctx, map[string]any{"op": "pair_ack", "npub": toNpub, "content": content})
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(out["event"])
	if err != nil {
		return nil, err
	}
	var ev nostr.Event
	if err := json.Unmarshal(raw, &ev); err != nil || ev.Kind != PairHelloKind {
		return nil, errors.New("nv-mesh gave no ack event")
	}
	return &ev, nil
}

// PairRelays carries kind-21195 events between the box and the finder
// relays, the relays the phones use to find the box (nv-mesh's
// NV_MESH_RELAYS). The hello comes in here; the ack goes out here.
type PairRelays interface {
	// Listen calls onEvent for each kind-21195 event to boxHex from since
	// (unix s), on every relay, until ctx ends.
	Listen(ctx context.Context, boxHex string, since int64, onEvent func(*nostr.Event))
	// Publish sends ev to every relay; how many took it.
	Publish(ctx context.Context, ev *nostr.Event) int
}

// FinderRelays is PairRelays over go-nostr.
type FinderRelays struct {
	URLs    []string
	Timeout time.Duration // per connect and publish; 10 s when 0
}

func (f FinderRelays) timeout() time.Duration { return orDur(f.Timeout, 10*time.Second) }

func (f FinderRelays) Listen(ctx context.Context, boxHex string, since int64, onEvent func(*nostr.Event)) {
	ts := nostr.Timestamp(since)
	filter := nostr.Filter{Kinds: []int{PairHelloKind}, Tags: nostr.TagMap{"p": {boxHex}}, Since: &ts}
	var wg sync.WaitGroup
	for _, url := range f.URLs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cctx, cancel := context.WithTimeout(ctx, f.timeout())
			r, err := nostr.RelayConnect(cctx, url)
			cancel()
			if err != nil {
				return
			}
			defer r.Close()
			sub, err := r.Subscribe(ctx, nostr.Filters{filter})
			if err != nil {
				return
			}
			for {
				select {
				case <-ctx.Done():
					return
				case ev, ok := <-sub.Events:
					if !ok {
						return
					}
					if ev != nil {
						onEvent(ev)
					}
				}
			}
		}()
	}
	wg.Wait()
}

func (f FinderRelays) Publish(ctx context.Context, ev *nostr.Event) int {
	var mu sync.Mutex
	var wg sync.WaitGroup
	took := 0
	for _, url := range f.URLs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cctx, cancel := context.WithTimeout(ctx, f.timeout())
			defer cancel()
			r, err := nostr.RelayConnect(cctx, url)
			if err != nil {
				return
			}
			defer r.Close()
			if err := r.Publish(cctx, *ev); err != nil {
				return
			}
			mu.Lock()
			took++
			mu.Unlock()
		}()
	}
	wg.Wait()
	return took
}

// pairErr is the error text the box UI shows for a failed nv-mesh ask.
func pairErr(err error) string {
	return fmt.Sprintf("the box's mesh could not finish the pairing: %v", err)
}
