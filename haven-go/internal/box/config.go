// Package box is the Linux home vault ("nostr-vault-linux"): the owner-only
// box API, the single front door on NV_PORT, the supervisor that runs the
// vault engine, and the mesh files it shares with nv-mesh. cmd/havend wires
// it together.
package box

import (
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// Config is everything the box reads from its environment. The owner comes
// from the installer (NV_OWNER); nothing on the box can claim or change it.
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
	// MeshDoorPort is the engine's loopback mesh door (NV_MESH_DOOR_PORT,
	// default Port+1), where nv-mesh sends strangers. The engine gets it as
	// HAVEN_MESH_PLAIN_PORT.
	MeshDoorPort int
	// UpdateHook, if set, is run on POST update. Otherwise the request is left
	// as a file for the container side to pick up.
	UpdateHook string
	// MoveRoot is the only tree POST move may move the vault into.
	MoveRoot string
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

// ConfigFromEnv reads the box's settings through getenv (os.Getenv in main).
func ConfigFromEnv(getenv func(string) string) (Config, error) {
	c := Config{
		DataDir:        orDefault(getenv("NV_DATA_DIR"), "/data"),
		WebDir:         getenv("NV_WEB_DIR"),
		EngineBin:      orDefault(getenv("NV_ENGINE_BIN"), "/usr/local/bin/haven-engine"),
		RelayURL:       getenv("NV_RELAY_URL"),
		Version:        getenv("NV_VERSION"),
		MeshStatusFile: getenv("NV_MESH_STATUS_FILE"),
		UpdateHook:     getenv("NV_UPDATE_HOOK"),
		MoveRoot:       orDefault(getenv("NV_MOVE_ROOT"), "/mnt"),
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
	if !filepath.IsAbs(c.MoveRoot) {
		return c, fmt.Errorf("NV_MOVE_ROOT must be an absolute path, got %q", c.MoveRoot)
	}
	c.MoveRoot = filepath.Clean(c.MoveRoot)
	if c.MeshStatusFile == "" {
		c.MeshStatusFile = filepath.Join(c.DataDir, "mesh", "status.json")
	}
	c.MeshNpubFile = filepath.Join(c.DataDir, "mesh", "npub")
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
	c.OwnerHex, c.OwnerNpub, err = ParseOwner(getenv("NV_OWNER"))
	return c, err
}

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
func (c Config) DefaultVaultDir() string { return filepath.Join(c.DataDir, "vault") }
