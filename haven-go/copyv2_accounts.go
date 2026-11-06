package main

// The vault's accounts in a copy, a backup zip and a catch-up
// (docs/MESH_COPY_V2_CONTRACT.md §3.4): look-only npubs and names, never keys.

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"slices"
	"sync"
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

// copyBroughtFile: the engine's own record of the accounts that came from
// another device (a copy, a catch-up or a backup zip) and were not this
// vault's then. Once ticked they are own, but the vault only ever reads them
// from relays and never uploads them (Logen, 2026-11-06: nothing is published
// or changed on relays for a brought-over account). Never sent anywhere;
// entries are never removed.
const copyBroughtFile = "copy-brought.json"

// copyKeepEntry is a copy's second list (notes.zip, right after
// accounts.json): every account whose notes A holds, signing or not (its own
// keys, look-only ones included, and the accounts brought over to it). B keeps
// those accounts' events read only (recorded as brought over), offers none of
// them and adds none: the offer stays accounts.json, signing accounts only
// (Logen, 2026-11-06). npubs only, same §3.4 check. Absent from an older A.
const copyKeepEntry = "keep.json"

// copyKeepMax: a keep list's cap (an npub entry is ~80 bytes, so this stays
// well under copyAccountsMaxSize).
const copyKeepMax = 512

type copyBroughtList struct {
	V        int      `json:"v"`
	Accounts []string `json:"accounts"` // npubs
}

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
	return copyListRefusal(raw, copyAccountsMax)
}

// copyListRefusal is copyAccountsRefusal with a cap on the entries (the keep
// list may be longer than the account list).
func copyListRefusal(raw []byte, maxEntries int) (copyAccountList, string) {
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
	if len(out.Accounts) == 0 || len(out.Accounts) > maxEntries {
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

// localCopyAccounts: this vault's accounts as it would send them (manifest,
// zip, catch-up): the owner, then each own key the app's copy-accounts.json
// lists (its signing accounts), as npubs with the file's names. A key that is
// own but not in the file (a look-only account: often someone else's npub)
// never travels (Tron, #1810): a device that ticked it would make it own
// there. No readable file: the owner only (fail closed). Listed but not own
// (offered, never ticked): not sent either.
func localCopyAccounts() copyAccountList {
	names := map[string]string{}
	listed := map[string]bool{}
	stamp := int64(0)
	if raw, err := os.ReadFile(copyAccountsFile); err == nil {
		if f, why := copyAccountsRefusal(raw); why == "" {
			stamp = f.UpdatedAt
			for _, a := range f.Accounts {
				if h, ok := npubHex(a.Npub); ok {
					names[h] = a.Name
					listed[h] = true
				}
			}
		}
	}
	own := whitelist()
	keys := make([]string, 0, len(own))
	for k := range own {
		if isLowerHex64(k) && (k == config.OwnerPubKey || listed[k]) {
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

// checkCopyAccounts: raw's accounts when they pass §3.4 and share one of this
// vault's own; otherwise the refusal (a §3.4 reason, or "no_shared_account").
// Adds nothing.
func checkCopyAccounts(raw []byte) (copyAccountList, string) {
	theirs, why := copyAccountsRefusal(raw)
	if why != "" {
		// Only npub + name may travel; anything else (a key, an ncryptsec, a
		// bunker or signer URI, a password field) is refused and said so.
		slog.Warn("accounts refused", "reason", why)
		return theirs, why
	}
	if !copySharesAccount(whitelist(), theirs.hexes()) {
		return theirs, "no_shared_account"
	}
	return theirs, ""
}

// takeCopyAccounts is the catch-up's side (§6): another device's list,
// checked and offered to the app, never added (Logen, 2026-11-06: only the
// accounts the person ticks become own, through AddAccountsC). Returns
// "offered" or the refusal.
func takeCopyAccounts(raw []byte) string {
	theirs, why := checkCopyAccounts(raw)
	if why != "" {
		return why
	}
	offerCopyAccounts(theirs)
	return "offered"
}

// offerCopyAccounts merges theirs into copy-accounts.json. The app asks the
// person which of those it lacks to add, and adds only the ticked ones
// (AddAccountsC and its whitelist file). Merging never removes one.
func offerCopyAccounts(theirs copyAccountList) {
	if err := recordBroughtAccounts(theirs); err != nil {
		// The catch-up restores nothing of theirs, and a copy recorded
		// them before its restore (and stopped on failure), so offering
		// stays safe.
		slog.Error("copy: could not record brought-over accounts", "error", err)
	}
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
}

var copyBroughtMu sync.Mutex

// recordBroughtAccounts adds to copy-brought.json every account in theirs that
// is not this vault's own now (the owner never is). It fails closed: an error
// means the list may not hold them, so the caller must not restore their
// events (they would be served and uploaded as if own). An existing list it
// can't read is an error too, never overwritten (that would drop its marks).
func recordBroughtAccounts(theirs copyAccountList) error {
	own := whitelist()
	copyBroughtMu.Lock()
	defer copyBroughtMu.Unlock()
	have, err := readBroughtNpubsStrict()
	if err != nil {
		return err
	}
	known := map[string]bool{}
	for _, n := range have {
		known[n] = true
	}
	next := have
	for _, a := range theirs.Accounts {
		h, ok := npubHex(a.Npub)
		if !ok || h == config.OwnerPubKey || known[a.Npub] {
			continue
		}
		if _, isOwn := own[h]; isOwn {
			continue
		}
		known[a.Npub] = true
		next = append(next, a.Npub)
	}
	if len(next) == len(have) {
		return nil
	}
	out, err := json.Marshal(copyBroughtList{V: 1, Accounts: next})
	if err != nil {
		return fmt.Errorf("brought-over list: %w", err)
	}
	tmp := copyBroughtFile + ".tmp"
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return fmt.Errorf("brought-over list: %w", err)
	}
	if err := os.Rename(tmp, copyBroughtFile); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("brought-over list: %w", err)
	}
	return nil
}

// readBroughtNpubsStrict is readBroughtNpubs for the writer: no file is an
// empty list, but a file it can't read or parse is an error.
func readBroughtNpubsStrict() ([]string, error) {
	raw, err := os.ReadFile(copyBroughtFile)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("brought-over list: %w", err)
	}
	var l copyBroughtList
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, fmt.Errorf("brought-over list: %w", err)
	}
	return l.Accounts, nil
}

func readBroughtNpubs() []string {
	raw, err := os.ReadFile(copyBroughtFile)
	if err != nil {
		return nil
	}
	var l copyBroughtList
	if json.Unmarshal(raw, &l) != nil {
		return nil
	}
	return l.Accounts
}

// broughtAccounts: the hex keys of every brought-over account (never the
// owner). The owner-event sync downloads their events but never uploads one
// (outboxNegStore.QueryEvents).
func broughtAccounts() map[string]struct{} {
	copyBroughtMu.Lock()
	npubs := readBroughtNpubs()
	copyBroughtMu.Unlock()
	out := make(map[string]struct{}, len(npubs))
	for _, n := range npubs {
		if h, ok := npubHex(n); ok && h != config.OwnerPubKey {
			out[h] = struct{}{}
		}
	}
	return out
}

// localCopyKeep: the keep list A sends: the owner, then every other key whose
// notes this vault holds (whitelist(), look-only included, and
// broughtAccounts()), sorted, no names. Over copyKeepMax the rest is cut,
// loudly.
func localCopyKeep() copyAccountList {
	set := map[string]struct{}{}
	for k := range whitelist() {
		set[k] = struct{}{}
	}
	for k := range broughtAccounts() {
		set[k] = struct{}{}
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		if isLowerHex64(k) && k != config.OwnerPubKey {
			keys = append(keys, k)
		}
	}
	slices.Sort(keys)
	if isLowerHex64(config.OwnerPubKey) {
		keys = append([]string{config.OwnerPubKey}, keys...)
	}
	if len(keys) > copyKeepMax {
		slog.Warn("copy: keep list cut", "accounts", len(keys), "kept", copyKeepMax)
		keys = keys[:copyKeepMax]
	}
	out := copyAccountList{V: 1, UpdatedAt: time.Now().Unix()}
	for _, k := range keys {
		if npub, err := nip19.EncodePublicKey(k); err == nil {
			out.Accounts = append(out.Accounts, copyAccount{Npub: npub})
		}
	}
	return out
}

func marshalLocalCopyKeep() []byte {
	l := localCopyKeep()
	if len(l.Accounts) == 0 {
		return nil
	}
	raw, _ := json.Marshal(l)
	return raw
}

func marshalLocalCopyAccounts() []byte {
	raw, _ := json.Marshal(localCopyAccounts())
	return raw
}

// errAccountsRefused: the zip's accounts.json failed §3.4 (a key, not an
// npub, or a malformed file). Nothing is restored.
var errAccountsRefused = errors.New("this backup's account list was refused")

func writeZipAccounts(zw *zip.Writer, raw []byte) error {
	return writeZipEntry(zw, copyAccountsEntry, raw)
}

func writeZipEntry(zw *zip.Writer, name string, raw []byte) error {
	w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate, Modified: time.Now()})
	if err != nil {
		return err
	}
	_, err = w.Write(raw)
	return err
}

// checkZipAccounts is the owner check of every restore (copy and backup zip
// alike). It only checks; it never adds a key. With accounts.json: refused
// (errAccountsRefused) unless it passes §3.4, not ours (errNotYourBackup)
// unless it shares one of this vault's accounts; has is true and theirs is
// the list. Without it (an older zip): ours only when its own notes hold one
// by the owner, as before. No owner: nothing to check.
func checkZipAccounts(path string) (theirs copyAccountList, has bool, err error) {
	if config.OwnerPubKey == "" {
		return theirs, false, nil
	}
	zr, err := zip.OpenReader(path)
	if err != nil {
		return theirs, false, err
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
			return theirs, false, err
		}
		if !ours {
			return theirs, false, errNotYourBackup
		}
		return theirs, false, nil
	}
	defer zr.Close()
	rc, err := entry.Open()
	if err != nil {
		return theirs, false, err
	}
	raw, err := io.ReadAll(io.LimitReader(rc, copyAccountsMaxSize+1))
	rc.Close()
	if err != nil {
		return theirs, false, err
	}
	theirs, why := checkCopyAccounts(raw)
	switch why {
	case "":
		return theirs, true, nil
	case "no_shared_account":
		return theirs, false, errNotYourBackup
	default:
		slog.Warn("restore: accounts refused", "reason", why)
		return theirs, false, errAccountsRefused
	}
}

// checkZipKeep reads a copy's keep list (copyKeepEntry): the hex keys whose
// events B keeps read only. No entry (an older A): nil. An entry that fails
// §3.4 (a key, a secret, a malformed file) refuses the whole copy
// (errAccountsRefused), as accounts.json does. Adds nothing.
func checkZipKeep(path string) ([]string, error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	for _, f := range zr.File {
		if f.Name != copyKeepEntry {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		raw, err := io.ReadAll(io.LimitReader(rc, copyAccountsMaxSize+1))
		rc.Close()
		if err != nil {
			return nil, err
		}
		list, why := copyListRefusal(raw, copyKeepMax)
		if why != "" {
			slog.Warn("restore: keep list refused", "reason", why)
			return nil, errAccountsRefused
		}
		return list.hexes(), nil
	}
	return nil, nil
}

// keepOnly: the keep list's accounts that accounts.json does not name. These
// are recorded as brought over before the restore (read only from the first
// event); the named ones go through the offer as before.
func keepOnly(keep []string, theirs copyAccountList) copyAccountList {
	named := map[string]bool{}
	for _, h := range theirs.hexes() {
		named[h] = true
	}
	out := copyAccountList{V: 1}
	for _, h := range keep {
		if named[h] {
			continue
		}
		if npub, err := nip19.EncodePublicKey(h); err == nil {
			out.Accounts = append(out.Accounts, copyAccount{Npub: npub})
		}
	}
	return out
}

// notOwnCount: how many of theirs are not this vault's own.
func notOwnCount(theirs copyAccountList) int {
	own := whitelist()
	n := 0
	for _, h := range theirs.hexes() {
		if _, ok := own[h]; !ok {
			n++
		}
	}
	return n
}
