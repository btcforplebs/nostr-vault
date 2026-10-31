package box

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// DeviceKey is the box's own key: made on first boot, kept in the data dir,
// never sent anywhere. Its npub is what the owner adds in My Devices. It is
// not the owner's key and can sign nothing as the owner.
type DeviceKey struct {
	secret string // hex; unexported so it never lands in JSON or %v
	Pubkey string
	Npub   string
}

// Secret is the hex secret, for the mesh engine that runs as this device.
func (k DeviceKey) Secret() string { return k.secret }

// String never prints the secret.
func (k DeviceKey) String() string { return "DeviceKey(" + k.Npub + ")" }

const deviceKeyFile = "device.key"

// LoadOrCreateDeviceKey reads dir/device.key, or makes it (0600, dir 0700)
// when it does not exist. A file that exists but is unreadable or malformed
// is an error, never a silent new key: a new key would drop the box out of
// My Devices.
func LoadOrCreateDeviceKey(dir string) (DeviceKey, error) {
	path := filepath.Join(dir, deviceKeyFile)
	raw, err := os.ReadFile(path)
	if err == nil {
		// A key restored or copied in by hand may be group/world readable.
		if info, serr := os.Stat(path); serr == nil && info.Mode().Perm()&0o077 != 0 {
			if cerr := os.Chmod(path, 0o600); cerr != nil {
				log.Printf("box: %s is readable by others (%v) and could not be tightened: %v", path, info.Mode().Perm(), cerr)
			} else {
				log.Printf("box: %s was readable by others (%v); set to 0600", path, info.Mode().Perm())
			}
		}
		return deviceKeyFrom(strings.TrimSpace(string(raw)), path)
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return DeviceKey{}, fmt.Errorf("reading device key: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return DeviceKey{}, fmt.Errorf("making %s: %w", dir, err)
	}
	sk := nostr.GeneratePrivateKey()
	tmp, err := os.CreateTemp(dir, ".device.key.*")
	if err != nil {
		return DeviceKey{}, fmt.Errorf("writing device key: %w", err)
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return DeviceKey{}, err
	}
	if _, err := tmp.WriteString(sk + "\n"); err != nil {
		tmp.Close()
		return DeviceKey{}, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return DeviceKey{}, err
	}
	if err := tmp.Close(); err != nil {
		return DeviceKey{}, err
	}
	// Link, not rename: if another start made the key first, keep that one.
	if err := os.Link(tmp.Name(), path); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return LoadOrCreateDeviceKey(dir)
		}
		return DeviceKey{}, fmt.Errorf("saving device key: %w", err)
	}
	return deviceKeyFrom(sk, path)
}

func deviceKeyFrom(sk, path string) (DeviceKey, error) {
	if b, err := hex.DecodeString(sk); err != nil || len(b) != 32 {
		return DeviceKey{}, fmt.Errorf("%s is not a 32-byte hex key; move it aside to make a new one (the box then needs approving again)", path)
	}
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		return DeviceKey{}, fmt.Errorf("%s: %w", path, err)
	}
	npub, err := nip19.EncodePublicKey(pk)
	if err != nil {
		return DeviceKey{}, err
	}
	return DeviceKey{secret: sk, Pubkey: pk, Npub: npub}, nil
}
