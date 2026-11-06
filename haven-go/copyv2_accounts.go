package main

// The vault's accounts in a copy, a backup zip and a catch-up
// (docs/MESH_COPY_V2_CONTRACT.md §3.4): look-only npubs and names, never keys.

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"slices"
	"time"
	"unicode/utf8"

	"github.com/nbd-wtf/go-nostr/nip19"
)

// copyAccountsEntry is the zip entry (notes.zip and backup zips), the first
// one, so B reads it before any store.
const copyAccountsEntry = "accounts.json"

// copyAccountsFile: the accounts the app should list, in the engine's working
// dir, next to copy-settings.json. The app writes it on A (names included);
// the engine merges what it is given into it on B, and the app adds any new
// npub to its own account list (look-only) and its whitelist file.
const copyAccountsFile = "copy-accounts.json"

const (
	copyAccountsMax     = 64
	copyAccountNameMax  = 80 // runes
	copyAccountsMaxSize = 64 << 10
)

type copyAccount struct {
	Npub string `json:"npub"`
	Name string `json:"name,omitempty"`
}

type copyAccountList struct {
	V         int           `json:"v"`
	UpdatedAt int64         `json:"updated_at"`
	Accounts  []copyAccount `json:"accounts"`
}

// copyAccountsRefusal: why raw may not be taken ("" = it may), with the
// file's accounts. bad_version, secret_value, unknown_key, bad_npub,
// bad_name, too_many. Secrets are looked for first, anywhere in the file, so
// a key pasted where an npub goes reads as a key (nsec1…, 64 hex).
func copyAccountsRefusal(raw []byte) (copyAccountList, string) {
	var out copyAccountList
	if len(raw) > copyAccountsMaxSize {
		return out, "too_many"
	}
	var whole any
	if err := json.Unmarshal(raw, &whole); err != nil {
		return out, "bad_version"
	}
	if copySecretAnywhere(whole) {
		return out, "secret_value"
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&out); err != nil {
		return copyAccountList{}, "unknown_key"
	}
	if out.V != 1 {
		return copyAccountList{}, "bad_version"
	}
	if len(out.Accounts) == 0 || len(out.Accounts) > copyAccountsMax {
		return copyAccountList{}, "too_many"
	}
	for _, a := range out.Accounts {
		if _, ok := npubHex(a.Npub); !ok {
			return copyAccountList{}, "bad_npub"
		}
		if !utf8.ValidString(a.Name) || utf8.RuneCountInString(a.Name) > copyAccountNameMax {
			return copyAccountList{}, "bad_name"
		}
	}
	return out, ""
}

// npubHex: the hex pubkey an npub names.
func npubHex(npub string) (string, bool) {
	prefix, v, err := nip19.Decode(npub)
	if err != nil || prefix != "npub" {
		return "", false
	}
	pk, ok := v.(string)
	return pk, ok && isLowerHex64(pk)
}

func (a copyAccountList) hexes() []string {
	out := make([]string, 0, len(a.Accounts))
	for _, x := range a.Accounts {
		if h, ok := npubHex(x.Npub); ok {
			out = append(out, h)
		}
	}
	return out
}

// copySharesAccount: whether theirs holds at least one of mine. B takes
// another device's accounts only then (Logen, 2026-11-06).
func copySharesAccount(mine map[string]struct{}, theirs []string) bool {
	return slices.ContainsFunc(theirs, func(h string) bool {
		_, ok := mine[h]
		return ok
	})
}

// mergeCopyAccounts: mine, then theirs that are new, in order. A name I have
// stays mine; a name I lack comes from theirs. Nothing is ever removed.
func mergeCopyAccounts(mine, theirs []copyAccount) []copyAccount {
	out := slices.Clone(mine)
	at := map[string]int{}
	for i, a := range out {
		at[a.Npub] = i
	}
	for _, a := range theirs {
		if i, ok := at[a.Npub]; ok {
			if out[i].Name == "" {
				out[i].Name = a.Name
			}
			continue
		}
		at[a.Npub] = len(out)
		out = append(out, a)
	}
	return out
}

// localCopyAccounts: this vault's accounts as it would send them: every own
// key as an npub (owner first), named from the app's copy-accounts.json.
func localCopyAccounts() copyAccountList {
	names := map[string]string{}
	stamp := int64(0)
	if raw, err := os.ReadFile(copyAccountsFile); err == nil {
		if f, why := copyAccountsRefusal(raw); why == "" {
			stamp = f.UpdatedAt
			for _, a := range f.Accounts {
				if h, ok := npubHex(a.Npub); ok {
					names[h] = a.Name
				}
			}
		}
	}
	own := whitelist()
	keys := make([]string, 0, len(own))
	for k := range own {
		if isLowerHex64(k) {
			keys = append(keys, k)
		}
	}
	slices.Sort(keys)
	if i := slices.Index(keys, config.OwnerPubKey); i > 0 {
		keys = append([]string{config.OwnerPubKey}, slices.Delete(keys, i, i+1)...)
	}
	out := copyAccountList{V: 1, UpdatedAt: stamp}
	for _, k := range keys {
		if npub, err := nip19.EncodePublicKey(k); err == nil {
			out.Accounts = append(out.Accounts, copyAccount{Npub: npub, Name: names[k]})
		}
	}
	if len(out.Accounts) > copyAccountsMax {
		out.Accounts = out.Accounts[:copyAccountsMax]
	}
	if out.UpdatedAt == 0 {
		out.UpdatedAt = time.Now().Unix()
	}
	return out
}

// takeCopyAccounts is the one place another device's accounts go in: checked,
// taken only when they share one of this vault's own, made own now (no
// restart), and merged into copy-accounts.json for the app. Returns "added"
// (or "same"), or the refusal: a §3.4 reason, or "no_shared_account".
func takeCopyAccounts(raw []byte) string {
	theirs, why := copyAccountsRefusal(raw)
	if why != "" {
		return why
	}
	if !copySharesAccount(whitelist(), theirs.hexes()) {
		return "no_shared_account"
	}
	added := addLiveAccounts(theirs.hexes())
	var mine copyAccountList
	if raw, err := os.ReadFile(copyAccountsFile); err == nil {
		if f, why := copyAccountsRefusal(raw); why == "" {
			mine = f
		}
	}
	merged := mergeCopyAccounts(mine.Accounts, theirs.Accounts)
	if len(merged) > copyAccountsMax {
		merged = merged[:copyAccountsMax]
	}
	if len(merged) != len(mine.Accounts) || !slices.Equal(merged, mine.Accounts) {
		out, _ := json.Marshal(copyAccountList{V: 1, UpdatedAt: time.Now().Unix(), Accounts: merged})
		tmp := copyAccountsFile + ".tmp"
		if os.WriteFile(tmp, out, 0o600) == nil {
			_ = os.Rename(tmp, copyAccountsFile)
		}
	}
	if added > 0 {
		return "added"
	}
	return "same"
}

func marshalLocalCopyAccounts() []byte {
	raw, _ := json.Marshal(localCopyAccounts())
	return raw
}

// errAccountsRefused: the zip's accounts.json failed §3.4 (a key, not an
// npub, or a malformed file). Nothing is restored.
var errAccountsRefused = errors.New("this backup's account list was refused")

func writeZipAccounts(zw *zip.Writer, raw []byte) error {
	w, err := zw.CreateHeader(&zip.FileHeader{Name: copyAccountsEntry, Method: zip.Deflate, Modified: time.Now()})
	if err != nil {
		return err
	}
	_, err = w.Write(raw)
	return err
}

// takeZipAccounts is the owner check of every restore (copy and backup zip
// alike). With accounts.json: refused (errAccountsRefused) unless it passes
// §3.4, not ours (errNotYourBackup) unless it shares one of this vault's
// accounts; otherwise its accounts become this vault's before any store is
// read, so their notes are kept. Without it (an older zip): ours only when
// its own notes hold one by the owner, as before. No owner: nothing to check.
func takeZipAccounts(path string) error {
	if config.OwnerPubKey == "" {
		return nil
	}
	zr, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	var entry *zip.File
	for _, f := range zr.File {
		if f.Name == copyAccountsEntry {
			entry = f
			break
		}
	}
	if entry == nil {
		zr.Close()
		ours, err := zipHasEventBy(path, config.OwnerPubKey)
		if err != nil {
			return err
		}
		if !ours {
			return errNotYourBackup
		}
		return nil
	}
	defer zr.Close()
	rc, err := entry.Open()
	if err != nil {
		return err
	}
	raw, err := io.ReadAll(io.LimitReader(rc, copyAccountsMaxSize+1))
	rc.Close()
	if err != nil {
		return err
	}
	switch why := takeCopyAccounts(raw); why {
	case "added", "same":
		return nil
	case "no_shared_account":
		return errNotYourBackup
	default:
		slog.Warn("restore: accounts refused", "reason", why)
		return errAccountsRefused
	}
}
