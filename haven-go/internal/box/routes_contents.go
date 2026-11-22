package box

import (
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Contents and connections: what the vault holds and who is on it, for the
// web dashboard's In your vault and Status card in box mode (One Vault E4).
//
// Note counts are not here on purpose. The browser asks the box's own relay
// with NIP-45 COUNT (web-vault/src/net/vault-contents.js), signed in as the
// account asking, so the engine applies each account's private-read rules.
// havend cannot open the engine's databases while it runs, and counting
// through a back door would show one account's private counts to another.
func init() {
	handle("GET /api/box/contents", SignedIn, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		dir := a.Mover.Engine.VaultDir()
		st := a.Storage.Measure(dir)
		writeJSON(w, http.StatusOK, Contents{
			VaultDir:   dir,
			MeasuredAt: st.MeasuredAt,
			Disk:       st.Disk,
			Split:      Split{Database: st.DatabaseBytes, Media: st.BlossomBytes, Other: st.OtherBytes},
			Media:      boxMedia.Measure(filepath.Join(dir, "blossom")),
		})
	})
	handle("GET /api/box/connections", SignedIn, func(_ *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		writeJSON(w, http.StatusOK, relayConns.snapshot())
	})
}

// Contents is GET /api/box/contents. Bytes are space on disk.
type Contents struct {
	VaultDir   string `json:"vaultDir"`
	MeasuredAt int64  `json:"measuredAt"`
	Disk       Disk   `json:"disk"`
	Split      Split  `json:"split"`
	Media      Media  `json:"media"`
}

// Split is the vault folder by what uses it: the engine's databases, the
// Blossom files, and everything else (backups, import state, lists).
type Split struct {
	Database uint64 `json:"database"`
	Media    uint64 `json:"media"`
	Other    uint64 `json:"other"`
}

// Media is the vault's own Blossom files by type, the shape the browser's
// scanMedia gives (vault-contents.js): { count, size, buckets: { image, video,
// audio, other } }, so the dashboard reads either the same way.
type Media struct {
	Count   int                    `json:"count"`
	Size    uint64                 `json:"size"`
	Buckets map[string]MediaBucket `json:"buckets"`
}

type MediaBucket struct {
	Count int    `json:"count"`
	Size  uint64 `json:"size"`
}

var mediaBuckets = []string{"image", "video", "audio", "other"}

// MediaMeter types the Blossom files at most once per TTL. A file's type is
// read from its first bytes once and kept while its size and time stay the
// same: Blossom names files by their hash, so a file never changes type.
type MediaMeter struct {
	TTL time.Duration

	mu     sync.Mutex
	dir    string
	at     time.Time
	cached Media
	typed  map[string]typedFile
}

type typedFile struct {
	size   int64
	mod    time.Time
	bucket string
}

var boxMedia = &MediaMeter{}

func (m *MediaMeter) Measure(dir string) Media {
	ttl := m.TTL
	if ttl == 0 {
		ttl = time.Minute
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.dir == dir && time.Since(m.at) < ttl {
		return m.cached
	}
	if m.dir != dir {
		m.typed = nil
	}
	out := Media{Buckets: map[string]MediaBucket{}}
	for _, b := range mediaBuckets {
		out.Buckets[b] = MediaBucket{}
	}
	seen := make(map[string]typedFile, len(m.typed))
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".") {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		tf, ok := m.typed[p]
		if !ok || tf.size != info.Size() || !tf.mod.Equal(info.ModTime()) {
			tf = typedFile{size: info.Size(), mod: info.ModTime(), bucket: sniffFile(p)}
		}
		seen[p] = tf
		size := onDisk(info)
		b := out.Buckets[tf.bucket]
		b.Count++
		b.Size += size
		out.Buckets[tf.bucket] = b
		out.Count++
		out.Size += size
		return nil
	})
	m.dir, m.at, m.cached, m.typed = dir, time.Now(), out, seen
	return out
}

func sniffFile(p string) string {
	f, err := os.Open(p)
	if err != nil {
		return "other"
	}
	defer f.Close()
	head := make([]byte, 16)
	n, _ := io.ReadFull(f, head)
	return mediaBucketOf(head[:n])
}

var isoImageBrand = regexp.MustCompile(`^(avif|avis|heic|heix|mif1)`)

// mediaBucketOf types a file by its first bytes, as the browser and the
// phone do (vault-contents.js mediaBucket, detectMimeFromBytes).
func mediaBucketOf(b []byte) string {
	if len(b) < 4 {
		return "other"
	}
	at := func(i int, xs ...byte) bool {
		if len(b) < i+len(xs) {
			return false
		}
		for j, x := range xs {
			if b[i+j] != x {
				return false
			}
		}
		return true
	}
	ascii := func(i int, s string) bool { return at(i, []byte(s)...) }
	switch {
	case at(0, 0xff, 0xd8, 0xff), at(0, 0x89, 0x50, 0x4e, 0x47), ascii(0, "GIF8"), ascii(0, "RIFF") && ascii(8, "WEBP"):
		return "image"
	case ascii(4, "ftyp"):
		brand := ""
		if len(b) >= 12 {
			brand = string(b[8:12])
		}
		switch {
		case isoImageBrand.MatchString(brand):
			return "image"
		case strings.HasPrefix(brand, "M4A"):
			return "audio"
		}
		return "video"
	case at(0, 0x1a, 0x45, 0xdf, 0xa3):
		return "video" // webm / matroska
	case ascii(0, "ID3"), at(0, 0xff, 0xfb), at(0, 0xff, 0xf3), ascii(0, "OggS"), ascii(0, "fLaC"), ascii(0, "RIFF") && ascii(8, "WAVE"):
		return "audio"
	case ascii(0, "<svg"), ascii(0, "<?xm"):
		return "image"
	}
	return "other"
}

// Connections is GET /api/box/connections: relay connections open through
// the box's front door now, by route (/, /private, /chat, /inbox, /feed).
// The mesh's own door goes straight to the engine and is not counted here;
// status's mesh.peers counts the mesh.
type Connections struct {
	Open    int            `json:"open"`
	ByRoute map[string]int `json:"byRoute"`
}

type connCounter struct {
	mu      sync.Mutex
	byRoute map[string]int
}

var relayConns = &connCounter{byRoute: map[string]int{}}

// track counts one relay connection on route until the returned func runs.
func (c *connCounter) track(route string) func() {
	c.mu.Lock()
	c.byRoute[route]++
	c.mu.Unlock()
	return func() {
		c.mu.Lock()
		if c.byRoute[route]--; c.byRoute[route] <= 0 {
			delete(c.byRoute, route)
		}
		c.mu.Unlock()
	}
}

func (c *connCounter) snapshot() Connections {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := Connections{ByRoute: make(map[string]int, len(c.byRoute))}
	for r, n := range c.byRoute {
		out.ByRoute[r] = n
		out.Open += n
	}
	return out
}

var relayRoutes = map[string]bool{"/": true, "/private": true, "/chat": true, "/inbox": true, "/feed": true}

// relayRouteOf names a WebSocket's route for the count; anything else
// (a typo, a probe) is "other", so a stranger cannot grow the map.
func relayRouteOf(path string) string {
	if p := strings.TrimSuffix(path, "/"); relayRoutes[p] {
		return p
	}
	if path == "/" || path == "" {
		return "/"
	}
	return "other"
}
