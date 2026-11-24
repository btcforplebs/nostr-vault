//go:build !(js && wasm)

package main

// Which note links Auto-Mirror fetches, and the links it remembers
// (auto_mirror.go rule 1). Pure, so the choice is testable.

import (
	"encoding/json"
	"log/slog"
	"net/url"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
	"sync"

	"github.com/nbd-wtf/go-nostr"
)

// ── Which links to fetch (pure) ─────────────────────────────────────────

// blobHashOfURL: the SHA-256 a Blossom-style link is named by
// (…/<64 hex>[.ext]), lower-cased; "" for any other link.
func blobHashOfURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	name := path.Base(u.Path)
	if i := strings.IndexByte(name, '.'); i >= 0 {
		name = name[:i]
	}
	name = strings.ToLower(name)
	if isBlobHash(name) {
		return name
	}
	return ""
}

// imetaHashes: url -> x from a note's imeta tags (NIP-92), lower-cased hashes only.
func imetaHashes(tags nostr.Tags) map[string]string {
	out := map[string]string{}
	for _, tag := range tags {
		if len(tag) == 0 || tag[0] != "imeta" {
			continue
		}
		var u, x string
		for _, f := range tag[1:] {
			switch {
			case strings.HasPrefix(f, "url "):
				u = strings.TrimSpace(strings.TrimPrefix(f, "url "))
			case strings.HasPrefix(f, "x "):
				x = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(f, "x ")))
			}
		}
		if u != "" && isBlobHash(x) {
			out[u] = x
		}
	}
	return out
}

var noteLinkRe = regexp.MustCompile(`https?://[^\s<>"'\]\[)(]+`)

var mediaExts = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true, ".webp": true, ".heic": true, ".heif": true,
	".avif": true, ".bmp": true, ".svg": false, // svg can run script: never
	".mp4": true, ".mov": true, ".m4v": true, ".webm": true, ".mkv": true,
	".mp3": true, ".m4a": true, ".aac": true, ".ogg": true, ".opus": true, ".wav": true, ".flac": true,
}

// noteMediaLinks: the media links in a note, in order: imeta urls, then
// links in the text that end in a media extension or are hash-named.
func noteMediaLinks(ev *nostr.Event) []string {
	var out []string
	seen := map[string]bool{}
	add := func(u string) {
		if !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	for _, tag := range ev.Tags {
		if len(tag) > 0 && tag[0] == "imeta" {
			for _, f := range tag[1:] {
				if strings.HasPrefix(f, "url ") {
					add(strings.TrimSpace(strings.TrimPrefix(f, "url ")))
				}
			}
		}
	}
	for _, m := range noteLinkRe.FindAllString(ev.Content, -1) {
		m = strings.TrimRight(m, ".,;:!?")
		u, err := url.Parse(m)
		if err != nil {
			continue
		}
		if blobHashOfURL(m) != "" || mediaExts[strings.ToLower(path.Ext(u.Path))] {
			add(m)
		}
	}
	return out
}

// linkPicker picks the links to fetch: each once, outside http(s) servers
// only, and never a file the vault holds or one already picked under
// another link. iOS/Android NoteMediaScan.Picker.
type linkPicker struct {
	stored func(sha string) bool
	seen   map[string]bool
	hashes map[string]bool
}

func newLinkPicker(stored func(string) bool) *linkPicker {
	return &linkPicker{stored: stored, seen: map[string]bool{}, hashes: map[string]bool{}}
}

// offer: true the first time an outside link not stored here comes by.
// known gives a hash for a link that is not hash-named (imeta, ledger).
func (p *linkPicker) offer(raw string, known func(string) string) bool {
	if p.seen[raw] {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil {
		return false
	}
	if forwardHostRefused(u.Hostname()) {
		return false
	}
	h := blobHashOfURL(raw)
	if h == "" && known != nil {
		h = strings.ToLower(known(raw))
	}
	if h != "" {
		if p.stored(h) || p.hashes[h] {
			return false
		}
		p.hashes[h] = true
	}
	p.seen[raw] = true
	return true
}

// ── The link ledger (rule 1 for links that are not hash-named) ──────────

type autoMirrorLinks struct {
	mu    sync.Mutex
	order []string
	bySha map[string]string
	dirty bool
}

func loadAutoMirrorLinks(file string) *autoMirrorLinks {
	l := &autoMirrorLinks{bySha: map[string]string{}}
	raw, err := os.ReadFile(file)
	if err != nil {
		return l
	}
	var saved struct {
		Links [][2]string `json:"links"` // oldest first
	}
	if json.Unmarshal(raw, &saved) != nil {
		slog.Warn("auto-mirror: unreadable links file, starting empty", "file", file)
		return l
	}
	for _, p := range saved.Links {
		if isBlobHash(p[1]) {
			if _, had := l.bySha[p[0]]; !had {
				l.order = append(l.order, p[0])
			}
			l.bySha[p[0]] = p[1]
		}
	}
	return l
}

func (l *autoMirrorLinks) hashFor(u string) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.bySha[u]
}

func (l *autoMirrorLinks) remember(u, sha string) {
	sha = strings.ToLower(sha)
	if !isBlobHash(sha) {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.bySha[u] == sha {
		return
	}
	if _, had := l.bySha[u]; had {
		l.order = slices.DeleteFunc(l.order, func(s string) bool { return s == u })
	}
	l.order = append(l.order, u)
	l.bySha[u] = sha
	for len(l.order) > autoMirrorLinksMax {
		delete(l.bySha, l.order[0])
		l.order = l.order[1:]
	}
	l.dirty = true
}

func (l *autoMirrorLinks) save(file string) error {
	l.mu.Lock()
	if !l.dirty {
		l.mu.Unlock()
		return nil
	}
	out := struct {
		Links [][2]string `json:"links"`
	}{Links: make([][2]string, 0, len(l.order))}
	for _, u := range l.order {
		out.Links = append(out.Links, [2]string{u, l.bySha[u]})
	}
	l.dirty = false
	l.mu.Unlock()
	raw, err := json.Marshal(out)
	if err != nil {
		return err
	}
	return writeFileAtomic(file, raw)
}

// writeFileAtomic writes through a temp file and a rename, so a reader (the
// box) never sees half a file.
func writeFileAtomic(file string, raw []byte) error {
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}
