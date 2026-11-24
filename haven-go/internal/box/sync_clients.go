package box

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

// MeshDial asks nv-mesh, over its dial.sock (linux/mesh/src/dial.rs), for
// the loopback base that reaches one of the owner's other vaults, and for a
// copy-start proof signed with the box's own mesh key. One JSON line each
// way. havend never holds that key, and no account key is ever asked for.
type MeshDial struct {
	Socket  string // <NV_MESH_RUN_DIR>/dial.sock
	Timeout time.Duration
}

func (d MeshDial) ask(ctx context.Context, req map[string]any) (map[string]any, error) {
	timeout := d.Timeout
	if timeout == 0 {
		timeout = 20 * time.Second // nv-mesh waits up to 15 s on a dial
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", d.Socket)
	if err != nil {
		return nil, fmt.Errorf("nv-mesh's dial socket: %w", err)
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	line, _ := json.Marshal(req)
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return nil, fmt.Errorf("nv-mesh's dial socket: %w", err)
	}
	raw, err := bufio.NewReader(io.LimitReader(conn, 64<<10)).ReadBytes('\n')
	if err != nil && len(raw) == 0 {
		return nil, fmt.Errorf("nv-mesh's dial socket: %w", err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, errors.New("nv-mesh's dial socket answered something that is not JSON")
	}
	if ok, _ := out["ok"].(bool); !ok {
		why, _ := out["error"].(string)
		return nil, fmt.Errorf("nv-mesh: %s", why)
	}
	return out, nil
}

// Dial: the loopback base that reaches npub's own-device port over the mesh.
// It holds an ingress token: never log it.
func (d MeshDial) Dial(ctx context.Context, npub string) (string, error) {
	out, err := d.ask(ctx, map[string]any{"op": "dial", "npub": npub})
	if err != nil {
		return "", err
	}
	base, _ := out["base"].(string)
	if base == "" {
		return "", errors.New("nv-mesh gave no base")
	}
	return base, nil
}

// SignCopyStart: the start proof for a first copy from npub through base,
// signed by the box's mesh key (base64 of a kind 27235).
func (d MeshDial) SignCopyStart(ctx context.Context, npub, base string) (string, error) {
	out, err := d.ask(ctx, map[string]any{"op": "sign_copy_start", "npub": npub, "base": base})
	if err != nil {
		return "", err
	}
	auth, _ := out["auth"].(string)
	if auth == "" {
		return "", errors.New("nv-mesh gave no proof")
	}
	return auth, nil
}

// EngineCopy is the engine's control socket (haven-go copyv2_box.go):
// start a first copy or a catch-up, read the per-device state.
type EngineCopy struct {
	Socket string // Config.EngineControlSocket
}

// ErrCopyBusy: the engine runs another copy or catch-up.
var ErrCopyBusy = errors.New("a copy or catch-up is running")

func (e EngineCopy) client() *http.Client {
	return &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", e.Socket)
		}},
	}
}

func (e EngineCopy) post(ctx context.Context, path string, body map[string]string) error {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://engine"+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := e.client().Do(req)
	if err != nil {
		return fmt.Errorf("the vault engine: %w", err)
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusAccepted:
		return nil
	case http.StatusConflict:
		return ErrCopyBusy
	}
	var out struct{ Error string }
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out)
	return fmt.Errorf("the vault engine: HTTP %d %s", resp.StatusCode, out.Error)
}

// First starts a first copy from peer.
func (e EngineCopy) First(ctx context.Context, peer, base, auth string) error {
	return e.post(ctx, "/copy/first", map[string]string{"peer": peer, "base": base, "auth": auth})
}

// Sync starts a catch-up with peer.
func (e EngineCopy) Sync(ctx context.Context, peer, base string) error {
	return e.post(ctx, "/copy/sync", map[string]string{"peer": peer, "base": base})
}

// CopyRun is one device's last run, as the engine records it.
type CopyRun struct {
	Kind     string `json:"kind"`
	Started  int64  `json:"started"`
	Finished int64  `json:"finished,omitempty"`
	Error    string `json:"error,omitempty"`
	Got      int    `json:"got,omitempty"`
	Sent     int    `json:"sent,omitempty"`
	Files    int    `json:"files,omitempty"`
	Gone     int    `json:"gone,omitempty"`
}

// CopyDevice is the engine's state for one device.
type CopyDevice struct {
	Peer     string   `json:"peer"`
	Token    bool     `json:"token"`
	SyncedAt int64    `json:"syncedAt,omitempty"`
	Last     *CopyRun `json:"last,omitempty"`
}

// CopyState is GET /copy/state.
type CopyState struct {
	Busy    bool         `json:"busy"`
	Running string       `json:"running,omitempty"`
	Devices []CopyDevice `json:"devices"`
}

// State reads the per-device state for peers.
func (e EngineCopy) State(ctx context.Context, peers []string) (CopyState, error) {
	var st CopyState
	q := url.Values{}
	for _, p := range peers {
		q.Add("peer", p)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://engine/copy/state?"+q.Encode(), nil)
	if err != nil {
		return st, err
	}
	resp, err := e.client().Do(req)
	if err != nil {
		return st, fmt.Errorf("the vault engine: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return st, fmt.Errorf("the vault engine: HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&st); err != nil {
		return st, fmt.Errorf("the vault engine: %w", err)
	}
	return st, nil
}

// PrepareControlDir makes the engine's control dir havend's alone (0700)
// and refuses a link there. When the default /run dir can't be made (havend
// not started by root, so nothing made it), it falls back to box/run under
// the data dir, logged: the data dir is already that uid's, so this gives
// nothing new away (Tron #2385 L1). A dir set with NV_BOX_RUN_DIR never
// falls back.
func PrepareControlDir(c *Config) error {
	err := prepareDir(c.ControlDir())
	if err != nil && c.RunDir == DefaultRunDir {
		log.Printf("box: engine control dir %s: %v; using the data dir instead", c.RunDir, err)
		c.RunDir = ""
		err = prepareDir(c.ControlDir())
	}
	return err
}

func prepareDir(dir string) error {
	if fi, err := os.Lstat(dir); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a link", dir)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}
