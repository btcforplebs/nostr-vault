package main

// Mesh vault copy v2: the pure rules of docs/MESH_COPY_V2_CONTRACT.md, each
// tested against docs/fixtures/mesh-copy/ (copyv2_rules_test.go). No I/O here.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// copyChunkSize: every part is fetched and checked in 4 MiB pieces.
const copyChunkSize = 4194304

// copyMaxChunkFailures: the third bad copy of one chunk stops the copy.
const copyMaxChunkFailures = 3

// copyPart is one fetched file of a copy: notes.zip, or media.zip.
type copyPart struct {
	Name   string   `json:"name"`
	Size   int64    `json:"size"`
	SHA256 string   `json:"sha256"`
	Chunk  int64    `json:"chunk"`
	Chunks []string `json:"chunks"`
}

type copyProgress struct {
	StoresDone  int `json:"stores_done"`
	StoresTotal int `json:"stores_total"`
	FilesDone   int `json:"files_done"`
	FilesTotal  int `json:"files_total"`
}

type copyFiles struct {
	Count int   `json:"count"`
	Bytes int64 `json:"bytes"`
}

// copyManifest is A's answer to GET /copy/v2/<id>.
type copyManifest struct {
	V         int            `json:"v"`
	ID        string         `json:"id"`
	State     string         `json:"state"`
	Error     string         `json:"error"`
	Owner     string         `json:"owner"`
	CreatedAt int64          `json:"created_at"`
	Progress  copyProgress   `json:"progress"`
	Counts    map[string]int `json:"counts"`
	Files     copyFiles      `json:"files"`
	Settings  string         `json:"settings"`
	// Accounts: A's own keys as npubs (owner first), for B's owner check
	// before it fetches (§3.1, §3.4). Absent from an older A.
	Accounts []string   `json:"accounts,omitempty"`
	Parts    []copyPart `json:"parts"`
	ZipKey   string     `json:"zip_key"`
}

// copyZipKey names one built copy: the parts' hashes, in order.
func copyZipKey(parts []copyPart) string {
	hashes := make([]string, len(parts))
	for i, p := range parts {
		hashes[i] = p.SHA256
	}
	sum := sha256.Sum256([]byte(strings.Join(hashes, "\n")))
	return hex.EncodeToString(sum[:])
}

func isLowerHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// copyManifestError: why B refuses a manifest, or "" when it is a ready copy
// B can fetch: of ownerHex's vault, or of a vault that shares at least one of
// B's own keys (mine) in its accounts.
func copyManifestError(m copyManifest, ownerHex string, mine map[string]struct{}) string {
	switch {
	case m.State == "building":
		return "building"
	case m.State == "failed":
		if m.Error != "" {
			return m.Error
		}
		return "bad_manifest"
	case m.V > 2:
		return "unsupported_version"
	case m.V != 2 || m.State != "ready":
		return "bad_manifest"
	}
	theirs := make([]string, 0, len(m.Accounts))
	for _, npub := range m.Accounts {
		h, ok := npubHex(npub)
		if !ok {
			return "bad_manifest"
		}
		theirs = append(theirs, h)
	}
	if !strings.EqualFold(m.Owner, ownerHex) && !copySharesAccount(mine, theirs) {
		return "wrong_owner"
	}
	if len(m.Parts) == 0 || m.Parts[0].Name != "notes" || len(m.Parts) > 2 || (len(m.Parts) == 2 && m.Parts[1].Name != "media") {
		return "bad_manifest"
	}
	for _, p := range m.Parts {
		if p.Size < 0 || p.Chunk != copyChunkSize || !isLowerHex64(p.SHA256) {
			return "bad_manifest"
		}
		if int64(len(p.Chunks)) != int64(math.Ceil(float64(p.Size)/float64(copyChunkSize))) {
			return "bad_manifest"
		}
		for _, c := range p.Chunks {
			if !isLowerHex64(c) {
				return "bad_manifest"
			}
		}
	}
	if m.ZipKey != copyZipKey(m.Parts) {
		return "bad_manifest"
	}
	return ""
}

// copyState is B's resume file, copy-<id>.state.json.
type copyState struct {
	V        int              `json:"v"`
	ID       string           `json:"id"`
	ZipKey   string           `json:"zip_key"`
	Done     map[string][]int `json:"done"`
	Failures map[string]int   `json:"failures"`
	// Restored: parts already restored, so a resume does not run them again.
	Restored []string `json:"restored,omitempty"`
	// Partial: what the last restore could not write (store names, and
	// "files:<n>"). The copy is kept for the next attempt (§3.2 partial).
	Partial []string `json:"partial,omitempty"`
}

// copyPlan: which chunks of each part B still needs. restart: the state was
// for another build of the zip (A's copy expired and was rebuilt), so every
// part starts over.
func copyPlan(m copyManifest, st *copyState) (restart bool, need map[string][]int) {
	restart = st != nil && st.ZipKey != m.ZipKey
	need = map[string][]int{}
	for _, p := range m.Parts {
		have := map[int]bool{}
		if st != nil && !restart {
			for _, i := range st.Done[p.Name] {
				have[i] = true
			}
		}
		need[p.Name] = []int{}
		for i := range p.Chunks {
			if !have[i] {
				need[p.Name] = append(need[p.Name], i)
			}
		}
	}
	return restart, need
}

// copyChunkFailed: the count after one more bad copy of a chunk, and whether
// that stops the copy.
func copyChunkFailed(before int) (failures int, stop bool) {
	failures = before + 1
	return failures, failures >= copyMaxChunkFailures
}

// copyLine is one parsed COPY progress line.
type copyLine struct {
	Stage  string
	Part   string
	Bytes  [2]int64
	Items  [2]int64
	Source string
	Error  string
}

var copyStages = []string{"building", "fetching", "restoring", "relays", "done", "failed"}

// formatCopyLine writes the line every app parses (contract §3.3).
func formatCopyLine(l copyLine) string {
	s := "COPY stage=" + l.Stage + " part=" + l.Part +
		" bytes=" + strconv.FormatInt(l.Bytes[0], 10) + "/" + strconv.FormatInt(l.Bytes[1], 10) +
		" items=" + strconv.FormatInt(l.Items[0], 10) + "/" + strconv.FormatInt(l.Items[1], 10) +
		" source=" + l.Source
	if l.Error != "" {
		s += " error=" + l.Error
	}
	return s
}

// parseCopyLine reads a COPY line anywhere in a log line; false when it isn't
// one, or its keys are out of order or malformed.
func parseCopyLine(line string) (copyLine, bool) {
	i := strings.Index(line, "COPY ")
	if i < 0 {
		return copyLine{}, false
	}
	fields := strings.Fields(line[i+len("COPY "):])
	if len(fields) < 5 {
		return copyLine{}, false
	}
	val := func(f, key string) (string, bool) {
		v, ok := strings.CutPrefix(f, key+"=")
		return v, ok && v != ""
	}
	pair := func(s string) ([2]int64, bool) {
		a, b, ok := strings.Cut(s, "/")
		x, err1 := strconv.ParseInt(a, 10, 64)
		y, err2 := strconv.ParseInt(b, 10, 64)
		return [2]int64{x, y}, ok && err1 == nil && err2 == nil && x >= 0 && y >= 0
	}
	var l copyLine
	var ok bool
	if l.Stage, ok = val(fields[0], "stage"); !ok || !slices.Contains(copyStages, l.Stage) {
		return copyLine{}, false
	}
	if l.Part, ok = val(fields[1], "part"); !ok || !slices.Contains([]string{"notes", "media", "-"}, l.Part) {
		return copyLine{}, false
	}
	b, ok1 := val(fields[2], "bytes")
	it, ok2 := val(fields[3], "items")
	if !ok1 || !ok2 {
		return copyLine{}, false
	}
	if l.Bytes, ok = pair(b); !ok {
		return copyLine{}, false
	}
	if l.Items, ok = pair(it); !ok {
		return copyLine{}, false
	}
	if l.Source, ok = val(fields[4], "source"); !ok || (l.Source != "mesh" && l.Source != "relays") {
		return copyLine{}, false
	}
	for _, f := range fields[5:] {
		if v, ok := val(f, "error"); ok {
			l.Error = v
		}
	}
	return l, true
}

// ─── settings (contract §5) ────────────────────────────────────────────────

// copySettingsKey: one allowlisted key and its type
// (docs/fixtures/mesh-copy/settings-allowlist.json, which a test holds this to).
type copySettingsKey struct {
	Type     string
	Min, Max int
}

var copySettingsAllowlist = map[string]copySettingsKey{
	"feed_layouts":        {Type: "object<string>"},
	"zaps_only":           {Type: "bool"},
	"auto_load_new_posts": {Type: "bool"},
	"new_posts_pill":      {Type: "bool"},
	"wot_depth":           {Type: "int", Min: 0, Max: 3},
	"blocked_relays":      {Type: "string[]"},
	"dm_relays":           {Type: "string[]"},
	"media_servers":       {Type: "string[]"},
	"notifications":       {Type: "object<bool>"},
	// Desktop Vaults P10: the Vault list, merged per Vault id (copyVaultsMerge).
	"desktop_vaults": {Type: "object[]", Max: copyVaultsMax},
}

// copyVaultsMax: more Vaults than this and the settings file is refused.
const copyVaultsMax = 32

// copyVaultTombDays: a tombstone older than this is dropped on merge.
const copyVaultTombDays = 90

// copyVaultFields / copyTombFields: what a Vault and a tombstone may hold
// (settings-allowlist.json). Addresses only: never My Devices, a pairing or
// a key, so a copied Vault grants nothing (plan §2.6).
var (
	copyVaultFields = map[string]string{"id": "string", "name": "string?", "kind": "string?",
		"meshNpub": "npub?", "httpsURL": "https?", "order": "int", "updatedAt": "int"}
	copyTombFields = map[string]string{"id": "string", "deletedAt": "int"}
)

// copySettingsFutureSlack: a settings file dated further ahead than this is refused.
const copySettingsFutureSlack = 10 * time.Minute

var (
	copySecretMarkers = []string{"nsec1", "ncryptsec1", "nostr+walletconnect:", "bunker:"}
	copyHexRun        = regexp.MustCompile(`[0-9a-fA-F]{64}`)
)

// copySettings is settings.json.
type copySettings struct {
	V         int                        `json:"v"`
	UpdatedAt int64                      `json:"updated_at"`
	Keys      map[string]json.RawMessage `json:"keys"`
}

// copySecretString: s holds something that must never leave its device.
func copySecretString(s string) bool {
	lower := strings.ToLower(s)
	for _, m := range copySecretMarkers {
		if strings.Contains(lower, m) {
			return true
		}
	}
	return copyHexRun.MatchString(s)
}

// copySecretAnywhere scans every string in v, map keys included.
func copySecretAnywhere(v any) bool {
	switch t := v.(type) {
	case string:
		return copySecretString(t)
	case []any:
		return slices.ContainsFunc(t, copySecretAnywhere)
	case map[string]any:
		for k, x := range t {
			if copySecretString(k) || copySecretAnywhere(x) {
				return true
			}
		}
	}
	return false
}

func copyTypeOK(want copySettingsKey, v any) bool {
	switch want.Type {
	case "bool":
		_, ok := v.(bool)
		return ok
	case "int":
		f, ok := v.(float64)
		return ok && f == math.Trunc(f) && f >= float64(want.Min) && f <= float64(want.Max)
	case "string[]":
		list, ok := v.([]any)
		if !ok {
			return false
		}
		for _, x := range list {
			if _, ok := x.(string); !ok {
				return false
			}
		}
		return true
	case "object[]":
		return copyVaultsOK(v, want.Max)
	case "object<string>", "object<bool>":
		m, ok := v.(map[string]any)
		if !ok {
			return false
		}
		for _, x := range m {
			if want.Type == "object<string>" {
				if _, ok := x.(string); !ok {
					return false
				}
			} else if _, ok := x.(bool); !ok {
				return false
			}
		}
		return true
	}
	return false
}

// copyWholeNumber: v is a JSON number with no fraction, at least min.
func copyWholeNumber(v any, min float64) bool {
	f, ok := v.(float64)
	return ok && f == math.Trunc(f) && f >= min && f < 1e15
}

// copyVaultsOK checks desktop_vaults field by field: a list of Vaults and
// tombstones (an entry with deletedAt), each id once, at most max Vaults.
func copyVaultsOK(v any, max int) bool {
	list, ok := v.([]any)
	if !ok {
		return false
	}
	seen := map[string]bool{}
	vaults := 0
	for _, x := range list {
		e, ok := x.(map[string]any)
		if !ok {
			return false
		}
		fields := copyVaultFields
		if _, tomb := e["deletedAt"]; tomb {
			fields = copyTombFields
		} else {
			vaults++
		}
		for k := range e {
			if _, ok := fields[k]; !ok {
				return false
			}
		}
		for k, t := range fields {
			val, has := e[k]
			if !has {
				if strings.HasSuffix(t, "?") {
					continue
				}
				return false
			}
			str, isStr := val.(string)
			switch strings.TrimSuffix(t, "?") {
			case "string":
				if !isStr || (k == "id" && str == "") {
					return false
				}
			case "npub":
				if !isStr || !strings.HasPrefix(str, "npub1") {
					return false
				}
			case "https":
				if !isStr || !strings.HasPrefix(str, "https://") {
					return false
				}
			case "int":
				min := 0.0
				if k != "order" {
					min = 1
				}
				if !copyWholeNumber(val, min) {
					return false
				}
			}
		}
		if fields["meshNpub"] != "" && e["meshNpub"] == nil && e["httpsURL"] == nil {
			return false
		}
		id := e["id"].(string)
		if seen[id] {
			return false
		}
		seen[id] = true
	}
	return vaults <= max
}

// copyVaultStamp: a Vault's updatedAt, or a tombstone's deletedAt.
func copyVaultStamp(e map[string]any) (float64, bool) {
	if at, ok := e["deletedAt"].(float64); ok {
		return at, true
	}
	at, _ := e["updatedAt"].(float64)
	return at, false
}

// copyVaultsMerge merges two checked desktop_vaults lists per Vault id
// (plan §2.6, Tron S4; settings-vault-merge-cases.json): the newer stamp wins
// for each id, a tie keeps mine, and a tombstone removes a Vault only when it
// is newer. Tombstones older than 90 days are dropped. Out: Vaults by
// (order, id), then tombstones by id. It merges data only: it never reads or
// writes the paired set, so a copied Vault can't pair anything.
func copyVaultsMerge(mine, theirs []any, now time.Time) []any {
	byID := map[string]map[string]any{}
	for _, x := range mine {
		e := x.(map[string]any)
		byID[e["id"].(string)] = e
	}
	for _, x := range theirs {
		t := x.(map[string]any)
		id := t["id"].(string)
		m, has := byID[id]
		if !has {
			byID[id] = t
			continue
		}
		ts, tTomb := copyVaultStamp(t)
		ms, mTomb := copyVaultStamp(m)
		if ts > ms || (ts == ms && mTomb && !tTomb) {
			byID[id] = t
		}
	}
	oldest := float64(now.Add(-copyVaultTombDays * 24 * time.Hour).Unix())
	var vaults, tombs []map[string]any
	for _, e := range byID {
		if at, tomb := copyVaultStamp(e); tomb {
			if at >= oldest {
				tombs = append(tombs, e)
			}
		} else {
			vaults = append(vaults, e)
		}
	}
	slices.SortFunc(vaults, func(a, b map[string]any) int {
		if oa, ob := a["order"].(float64), b["order"].(float64); oa != ob {
			if oa < ob {
				return -1
			}
			return 1
		}
		return strings.Compare(a["id"].(string), b["id"].(string))
	})
	slices.SortFunc(tombs, func(a, b map[string]any) int { return strings.Compare(a["id"].(string), b["id"].(string)) })
	// Two lists that each pass can merge to more than copyVaultsMax Vaults;
	// the file would then be refused and settings sync between the two
	// devices stop. The Vaults past the cap, last in (order, id), are left
	// out, the same on both sides (Tron on #2521).
	if len(vaults) > copyVaultsMax {
		vaults = vaults[:copyVaultsMax]
	}
	out := make([]any, 0, len(vaults)+len(tombs))
	for _, e := range vaults {
		out = append(out, e)
	}
	for _, e := range tombs {
		out = append(out, e)
	}
	return out
}

// copySettingsMerge: the settings file after theirs meets mine (both already
// passed copySettingsRefusal; mine may be nil for none). Every key but
// desktop_vaults is whole-file: the newer updated_at's keys, a tie keeps
// mine. desktop_vaults merges per Vault (copyVaultsMerge) from both sides,
// whichever file won. updated_at is the newer of the two.
func copySettingsMerge(mine, theirs []byte, now time.Time) ([]byte, error) {
	type file struct {
		V         int            `json:"v"`
		UpdatedAt int64          `json:"updated_at"`
		Keys      map[string]any `json:"keys"`
	}
	var t file
	if err := json.Unmarshal(theirs, &t); err != nil {
		return nil, err
	}
	var m file
	if mine == nil || json.Unmarshal(mine, &m) != nil || m.Keys == nil {
		m = file{}
	}
	out := file{V: 1, UpdatedAt: max(m.UpdatedAt, t.UpdatedAt), Keys: map[string]any{}}
	winner := m.Keys
	if copySettingsNewer(m.UpdatedAt, t.UpdatedAt) || mine == nil {
		winner = t.Keys
	}
	for k, v := range winner {
		out.Keys[k] = v
	}
	mv, _ := m.Keys["desktop_vaults"].([]any)
	tv, _ := t.Keys["desktop_vaults"].([]any)
	// An empty list is left out, so a device on an engine from before the
	// Vault list (no desktop_vaults in its allowlist) still takes the file
	// (Tron on #2521, contract §5).
	delete(out.Keys, "desktop_vaults")
	if merged := copyVaultsMerge(mv, tv, now); len(merged) > 0 {
		out.Keys["desktop_vaults"] = merged
	}
	return json.Marshal(out)
}

// copySettingsSame: a and b hold the same settings, however each is spelled.
func copySettingsSame(a, b []byte) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	xs, _ := json.Marshal(x)
	ys, _ := json.Marshal(y)
	return string(xs) == string(ys)
}

// copySettingsRefusal: why raw may not be copied or applied ("" = it may):
// bad_version, unknown_key, bad_type or secret_value. Secrets are looked for
// first in the whole file, so a secret under an unknown key still reads as one.
func copySettingsRefusal(raw []byte, now time.Time) string {
	var whole any
	if err := json.Unmarshal(raw, &whole); err != nil {
		return "bad_version"
	}
	if copySecretAnywhere(whole) {
		return "secret_value"
	}
	var s struct {
		V         *int            `json:"v"`
		UpdatedAt *float64        `json:"updated_at"`
		Keys      *map[string]any `json:"keys"`
	}
	if err := json.Unmarshal(raw, &s); err != nil || s.V == nil || *s.V != 1 || s.UpdatedAt == nil || s.Keys == nil {
		return "bad_version"
	}
	if time.Unix(int64(*s.UpdatedAt), 0).After(now.Add(copySettingsFutureSlack)) {
		return "bad_version"
	}
	for k, v := range *s.Keys {
		want, ok := copySettingsAllowlist[k]
		if !ok {
			return "unknown_key"
		}
		if !copyTypeOK(want, v) {
			return "bad_type"
		}
	}
	// A Vault dated further ahead than the file may be would win every merge
	// for its id, and a tombstone so dated would never age out (Tron on
	// #2521). Bounded by now, not the file's updated_at: an app's first file
	// is dated 1 with its Vaults dated now.
	if list, ok := (*s.Keys)["desktop_vaults"].([]any); ok {
		limit := float64(now.Add(copySettingsFutureSlack).Unix())
		for _, x := range list {
			if at, _ := copyVaultStamp(x.(map[string]any)); at > limit {
				return "bad_type"
			}
		}
	}
	return ""
}

// copySettingsNewer: whether theirs replaces mine (0 = none). A tie keeps mine.
func copySettingsNewer(mine, theirs int64) bool {
	return theirs > 0 && theirs > mine
}

// ─── own files (contract §4) ────────────────────────────────────────────────

// copyOwnMedia: of the blob records (sha256 -> uploader), the vault's own
// files: every one whose record is by one of this vault's own keys. That is
// uploads, drafts, DM files the owner sent, and photos the owner saved or
// mirrored (Logen, 2026-11-05: what he saved counts as his). A record by any
// other key is left out; the upload gate (init.go RejectUpload) and the
// restore (jsonl.go importBlobRecord) never file one, so a photo someone only
// sent the owner is not in the store to begin with.
func copyOwnMedia(records map[string]string, accounts map[string]bool) map[string]bool {
	out := map[string]bool{}
	for sha, uploader := range records {
		if accounts[uploader] {
			out[sha] = true
		}
	}
	return out
}
