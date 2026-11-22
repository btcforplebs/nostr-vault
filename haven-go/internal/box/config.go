// Package box is the Linux home vault ("nostr-vault-linux"): the owner-only
// box API, the single front door on NV_PORT, the supervisor that runs the
// vault engine, and the mesh files it shares with nv-mesh. cmd/havend wires
// it together.
package box

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// Config is everything the box reads from its environment. The owner comes
// from the installer (NV_OWNER), or from box/owner, which only claim mode
// writes and only for someone holding the store's setup code
// (NV_SETUP_CODE, claim.go). Nothing else on the box can claim or change it.
type Config struct {
	// DataDir holds the box's own files (box/) and, unless moved, the vault (vault/).
	DataDir string
	// Port is the one port the box serves: relay, Blossom, web app, box API.
	Port int
	// OwnerHex is the owner's pubkey, lowercase hex. OwnerNpub is the same key.
	OwnerHex  string
	OwnerNpub string
	// WebDir is the built web app. Empty: GET / falls through to the vault's own page.
	WebDir string
	// EngineBin is the vault engine binary (haven-go built with -tags nolmdb).
	EngineBin string
	// EnginePort is the engine's loopback port. Only the front door talks to it.
	EnginePort int
	// RelayURL is what the engine calls itself (NIP-42 relay tag). Optional.
	RelayURL string
	// Version is the box build (ldflags or NV_VERSION).
	Version string
	// MeshStatusFile is where the mesh process writes its status JSON.
	MeshStatusFile string
	// MeshNpubFile is where nv-mesh writes the box's npub: the box's one
	// identity, the key the owner approves in My Devices.
	MeshNpubFile string
	// MeshDevicesFile is mesh-devices.json (NV_MESH_DEVICES): havend writes
	// it from the owner's server list, nv-mesh reads it.
	MeshDevicesFile string
	// MeshRunDir is nv-mesh's runtime dir (NV_MESH_RUN_DIR, default
	// /run/nv-mesh), where its dial.sock lets havend reach the owner's other
	// vaults (linux/mesh/src/dial.rs).
	MeshRunDir string
	// MeshDoorPort is the engine's loopback mesh door (NV_MESH_DOOR_PORT,
	// default Port+1), where nv-mesh sends strangers. The engine gets it as
	// HAVEN_MESH_PLAIN_PORT.
	MeshDoorPort int
	// UpdateHook, if set, is run on POST update. Otherwise the request is left
	// as a file for the container side to pick up.
	UpdateHook string
	// MoveRoot is the only tree POST move may move the vault into. Empty
	// (NV_MOVE_ROOT set to nothing): Move is off, because a store (StartOS,
	// Umbrel) owns the disk.
	MoveRoot string
	// UpdateVia names the store that updates the box ("startos", "umbrel");
	// POST update then answers managed. Empty: NV_UPDATE_HOOK or manual.
	UpdateVia string
	// SetupCode is NV_SETUP_CODE, used only while the box has no owner
	// (Claiming): the code a store shows its user, which claims the box.
	SetupCode string
	// DirectoryRelays are asked for the owner's server list (kind 10063)
	// when the vault itself has none yet.
	DirectoryRelays []string
}

// DefaultDirectoryRelays are the relays the apps write the owner's 10063 to
// (HavenConfig.starterRelays plus purplepag.es, the server-list indexer).
var DefaultDirectoryRelays = []string{
	"wss://relay.primal.net",
	"wss://relay.damus.io",
	"wss://relay.btcforplebs.com",
	"wss://purplepag.es",
}

// UpdateStores are the NV_UPDATE_VIA values: the stores that own updates.
var UpdateStores = map[string]bool{"startos": true, "umbrel": true}

// MinSetupCode is the shortest NV_SETUP_CODE the box takes: a short code
// could be guessed by a LAN visitor before the owner claims the box.
const MinSetupCode = 12

// ConfigFromEnv reads the box's settings through getenv. A variable set to
// "" reads as unset; use ConfigFromLookup (os.LookupEnv in main) to tell
// NV_MOVE_ROOT= (Move off) from no NV_MOVE_ROOT (/mnt).
func ConfigFromEnv(getenv func(string) string) (Config, error) {
	return ConfigFromLookup(func(k string) (string, bool) { v := getenv(k); return v, v != "" })
}

// ConfigFromLookup reads the box's settings through lookup (os.LookupEnv).
func ConfigFromLookup(lookup func(string) (string, bool)) (Config, error) {
	getenv := func(k string) string { v, _ := lookup(k); return v }
	c := Config{
		DataDir:        orDefault(getenv("NV_DATA_DIR"), "/data"),
		WebDir:         getenv("NV_WEB_DIR"),
		EngineBin:      orDefault(getenv("NV_ENGINE_BIN"), "/usr/local/bin/haven-engine"),
		RelayURL:       getenv("NV_RELAY_URL"),
		Version:        getenv("NV_VERSION"),
		MeshStatusFile: getenv("NV_MESH_STATUS_FILE"),
		UpdateHook:     getenv("NV_UPDATE_HOOK"),
		MoveRoot:       "/mnt",
		UpdateVia:      strings.ToLower(strings.TrimSpace(getenv("NV_UPDATE_VIA"))),
	}
	if v, set := lookup("NV_MOVE_ROOT"); set {
		c.MoveRoot = strings.TrimSpace(v)
	}
	if c.UpdateVia != "" && !UpdateStores[c.UpdateVia] {
		return c, fmt.Errorf("NV_UPDATE_VIA must be startos or umbrel, got %q", c.UpdateVia)
	}
	var err error
	if c.Port, err = port(getenv("NV_PORT"), 8080, "NV_PORT"); err != nil {
		return c, err
	}
	if c.EnginePort, err = port(getenv("NV_ENGINE_PORT"), 3355, "NV_ENGINE_PORT"); err != nil {
		return c, err
	}
	if c.EnginePort == c.Port {
		return c, errors.New("NV_ENGINE_PORT must differ from NV_PORT")
	}
	defDoor := c.Port + 1
	if defDoor > 65535 {
		defDoor = 0
	}
	if c.MeshDoorPort, err = port(getenv("NV_MESH_DOOR_PORT"), defDoor, "NV_MESH_DOOR_PORT"); err != nil {
		return c, err
	}
	if c.MeshDoorPort == 0 {
		return c, errors.New("NV_MESH_DOOR_PORT must be set when NV_PORT is 65535")
	}
	if c.MeshDoorPort == c.Port || c.MeshDoorPort == c.EnginePort {
		return c, errors.New("NV_MESH_DOOR_PORT must differ from NV_PORT and NV_ENGINE_PORT")
	}
	if !filepath.IsAbs(c.DataDir) {
		return c, fmt.Errorf("NV_DATA_DIR must be an absolute path, got %q", c.DataDir)
	}
	c.DataDir = filepath.Clean(c.DataDir)
	if c.MoveRoot != "" {
		if !filepath.IsAbs(c.MoveRoot) {
			return c, fmt.Errorf("NV_MOVE_ROOT must be an absolute path or empty (Move off), got %q", c.MoveRoot)
		}
		c.MoveRoot = filepath.Clean(c.MoveRoot)
	}
	if c.MeshStatusFile == "" {
		c.MeshStatusFile = filepath.Join(c.DataDir, "mesh", "status.json")
	}
	c.MeshNpubFile = filepath.Join(c.DataDir, "mesh", "npub")
	c.MeshRunDir = orDefault(strings.TrimSpace(getenv("NV_MESH_RUN_DIR")), "/run/nv-mesh")
	c.MeshDevicesFile = orDefault(getenv("NV_MESH_DEVICES"), filepath.Join(c.DataDir, "mesh-devices.json"))
	if !filepath.IsAbs(c.MeshDevicesFile) {
		return c, fmt.Errorf("NV_MESH_DEVICES must be an absolute path, got %q", c.MeshDevicesFile)
	}
	if c.Version == "" {
		c.Version = "dev"
	}
	c.DirectoryRelays = DefaultDirectoryRelays
	if v := strings.TrimSpace(getenv("NV_DIRECTORY_RELAYS")); v != "" {
		c.DirectoryRelays = nil
		for _, r := range strings.Split(v, ",") {
			if r = strings.TrimSpace(r); r != "" {
				c.DirectoryRelays = append(c.DirectoryRelays, r)
			}
		}
	}
	return c, c.readOwner(getenv("NV_OWNER"), getenv("NV_SETUP_CODE"))
}

// readOwner: NV_OWNER if set; else box/owner (a claim made earlier); else,
// with a setup code, claim mode (Claiming). A box/owner that is there but
// unreadable or not an npub is an error, never a way back into claim mode.
func (c *Config) readOwner(env, code string) error {
	var err error
	if strings.TrimSpace(env) != "" {
		c.OwnerHex, c.OwnerNpub, err = ParseOwner(env)
		return err
	}
	raw, ferr := os.ReadFile(c.OwnerFile())
	if ferr == nil {
		if c.OwnerHex, c.OwnerNpub, err = ParseOwner(string(raw)); err != nil {
			return fmt.Errorf("%s: %v", c.OwnerFile(), err)
		}
		return nil
	}
	if !errors.Is(ferr, fs.ErrNotExist) {
		return fmt.Errorf("reading %s: %v", c.OwnerFile(), ferr)
	}
	code = strings.TrimSpace(code)
	if code == "" {
		return errors.New("NV_OWNER is not set: the installer must name the owner's npub (or a store sets NV_SETUP_CODE for claim mode)")
	}
	if len(code) < MinSetupCode {
		return fmt.Errorf("NV_SETUP_CODE must be at least %d characters", MinSetupCode)
	}
	c.SetupCode = code
	return nil
}

// Claiming: no owner yet, so havend serves only the setup page (claim.go).
func (c Config) Claiming() bool { return c.OwnerHex == "" && c.SetupCode != "" }

// OwnerFile is box/owner: the owner npub claim mode saved.
func (c Config) OwnerFile() string { return filepath.Join(c.BoxDir(), "owner") }

// ParseOwner takes the installer's NV_OWNER (npub or 64-char hex) and returns
// both forms. An empty owner is an error: the box never lets the first
// visitor claim it.
func ParseOwner(raw string) (hexKey, npub string, err error) {
	raw = strings.TrimSpace(raw)
	raw = strings.TrimPrefix(raw, "nostr:")
	if raw == "" {
		return "", "", errors.New("NV_OWNER is not set: the installer must name the owner's npub")
	}
	if strings.HasPrefix(raw, "nsec") {
		return "", "", errors.New("NV_OWNER is a secret key (nsec); give the owner's npub, never the nsec")
	}
	if strings.HasPrefix(raw, "npub1") {
		prefix, v, derr := nip19.Decode(raw)
		if derr != nil || prefix != "npub" {
			return "", "", fmt.Errorf("NV_OWNER is not a valid npub: %v", derr)
		}
		hexKey = v.(string)
	} else {
		if len(raw) != 64 {
			return "", "", errors.New("NV_OWNER must be an npub or a 64-character hex pubkey")
		}
		if _, derr := hex.DecodeString(raw); derr != nil {
			return "", "", errors.New("NV_OWNER must be an npub or a 64-character hex pubkey")
		}
		hexKey = strings.ToLower(raw)
	}
	npub, err = nip19.EncodePublicKey(hexKey)
	if err != nil {
		return "", "", fmt.Errorf("NV_OWNER: %v", err)
	}
	return hexKey, npub, nil
}

func orDefault(v, d string) string {
	if strings.TrimSpace(v) == "" {
		return d
	}
	return strings.TrimSpace(v)
}

func port(raw string, def int, name string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return def, nil
	}
	p, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || p < 1 || p > 65535 {
		return 0, fmt.Errorf("%s must be a port number, got %q", name, raw)
	}
	return p, nil
}

// BoxDir holds the box's own files: state, update request. The box's key
// is the mesh's, in mesh/key/, which havend never reads.
func (c Config) BoxDir() string { return filepath.Join(c.DataDir, "box") }

// DefaultVaultDir is where the vault lives until it is moved.
// ControlDir holds the engine's control socket (EngineControlSocket): a
// 0700 dir of havend's, so only havend and its engine reach the socket.
func (c Config) ControlDir() string { return filepath.Join(c.BoxDir(), "run") }

// EngineControlSocket is HAVEN_BOX_CONTROL_SOCK (haven-go copyv2_box.go).
func (c Config) EngineControlSocket() string { return filepath.Join(c.ControlDir(), "engine.sock") }

func (c Config) DefaultVaultDir() string { return filepath.Join(c.DataDir, "vault") }
