package box

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeviceKeyMadeOnceAndKept(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "box")
	k1, err := LoadOrCreateDeviceKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(filepath.Join(dir, "device.key"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("device.key mode %v, want 0600", st.Mode().Perm())
	}
	if dst, _ := os.Stat(dir); dst.Mode().Perm() != 0o700 {
		t.Fatalf("box dir mode %v, want 0700", dst.Mode().Perm())
	}
	k2, err := LoadOrCreateDeviceKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	if k1.Npub != k2.Npub || k1.Secret() != k2.Secret() || !strings.HasPrefix(k1.Npub, "npub1") {
		t.Fatalf("second load made a new key: %s vs %s", k1, k2)
	}
	// The secret never shows up in logs or JSON.
	b, _ := json.Marshal(k1)
	for _, s := range []string{fmt.Sprint(k1), fmt.Sprintf("%+v", k1), k1.String(), string(b)} {
		if strings.Contains(s, k1.Secret()) {
			t.Fatalf("secret leaked in %q", s)
		}
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("temp files left behind: %v", entries)
	}
}

func TestDeviceKeyCorruptIsAnErrorNotANewKey(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "device.key"), []byte("not hex\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateDeviceKey(dir); err == nil {
		t.Fatal("corrupt key must be an error")
	}
	b, _ := os.ReadFile(filepath.Join(dir, "device.key"))
	if string(b) != "not hex\n" {
		t.Fatal("corrupt key file was overwritten")
	}
}

func TestDeviceKeyLooseModeTightened(t *testing.T) {
	dir := t.TempDir()
	k, err := LoadOrCreateDeviceKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, deviceKeyFile)
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	k2, err := LoadOrCreateDeviceKey(dir)
	if err != nil || k2.Pubkey != k.Pubkey {
		t.Fatalf("reload: %v %v", err, k2)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, want 0600", info.Mode().Perm())
	}
}
