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
	Parts     []copyPart     `json:"parts"`
	ZipKey    string         `json:"zip_key"`
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
// of ownerHex's vault it can fetch.
func copyManifestError(m copyManifest, ownerHex string) string {
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
	case !strings.EqualFold(m.Owner, ownerHex):
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
}

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
