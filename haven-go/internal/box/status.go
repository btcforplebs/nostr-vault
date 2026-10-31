package box

import (
	"bufio"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Disk is one filesystem's space, in bytes.
type Disk struct {
	Path  string `json:"path"`
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
	Used  uint64 `json:"used"`
}

// DiskOf reports the filesystem holding path.
func DiskOf(path string) (Disk, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return Disk{Path: path}, err
	}
	bsize := uint64(st.Bsize)
	total := uint64(st.Blocks) * bsize
	free := uint64(st.Bavail) * bsize
	used := total - uint64(st.Bfree)*bsize
	return Disk{Path: path, Total: total, Free: free, Used: used}, nil
}

// Mem is the box's memory, in bytes. System figures come from /proc/meminfo
// and are 0 where there is none (macOS test runs).
type Mem struct {
	// Used and Total are the box's memory for the screens (Total minus
	// MemAvailable). Absent, not 0, where /proc/meminfo is missing.
	Used  *uint64 `json:"used,omitempty"`
	Total *uint64 `json:"total,omitempty"`

	SystemTotal     uint64 `json:"systemTotal"`
	SystemAvailable uint64 `json:"systemAvailable"`
	EngineRSS       uint64 `json:"engineRss"`
	BoxRSS          uint64 `json:"boxRss"`
	BoxHeap         uint64 `json:"boxHeap"`
}

func readMem(enginePid int) Mem {
	var m Mem
	if kv := procKV("/proc/meminfo"); kv != nil {
		m.SystemTotal = kv["MemTotal"]
		m.SystemAvailable = kv["MemAvailable"]
		if m.SystemTotal > 0 && m.SystemAvailable <= m.SystemTotal {
			total, used := m.SystemTotal, m.SystemTotal-m.SystemAvailable
			m.Total, m.Used = &total, &used
		}
	}
	if kv := procKV("/proc/self/status"); kv != nil {
		m.BoxRSS = kv["VmRSS"]
	}
	if enginePid > 0 {
		if kv := procKV("/proc/" + strconv.Itoa(enginePid) + "/status"); kv != nil {
			m.EngineRSS = kv["VmRSS"]
		}
	}
	var rs runtime.MemStats
	runtime.ReadMemStats(&rs)
	m.BoxHeap = rs.HeapAlloc
	return m
}

// procKV reads "Key:   123 kB" lines into bytes.
func procKV(path string) map[string]uint64 {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	out := map[string]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		fields := strings.Fields(v)
		if len(fields) == 0 {
			continue
		}
		n, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		if len(fields) > 1 && fields[1] == "kB" {
			n *= 1024
		}
		out[k] = n
	}
	return out
}

// Status is GET /api/box/status.
type Status struct {
	Version string         `json:"version"`
	Uptime  int64          `json:"uptime"` // seconds since havend started
	Mem     Mem            `json:"mem"`
	Disk    Disk           `json:"disk"`
	Mesh    map[string]any `json:"mesh"`
	Engine  EngineState    `json:"engine"`
	Owner   string         `json:"owner"`
	Device  string         `json:"device"` // the box's one npub (the mesh's); "" until nv-mesh made it
	Move    *MoveState     `json:"move,omitempty"`
}

// meshStale: a status.json older than this is from an nv-mesh that has
// stopped writing (it writes every 5 s), so the mesh reads as down.
const meshStale = 30 * time.Second

// readMesh turns nv-mesh's status.json (linux/mesh/README.md: the engine's
// status plus npub, devices, error, updated) into the screens' mesh object
// {up, npub, peers} (web-vault/src/box/api.js), keeping nv-mesh's own fields
// alongside. up is the engine's "running", and only while the file is fresh.
// peers is a count: the length of the engine's peer list. No file, or one
// that is not a JSON object, reads as down. npub is the box's mesh npub.
func readMesh(path, boxNpub string, now time.Time) map[string]any {
	m := map[string]any{}
	if b, err := os.ReadFile(path); err == nil && len(b) <= 64<<10 {
		_ = json.Unmarshal(b, &m)
		if m == nil {
			m = map[string]any{}
		}
	}
	running, _ := m["running"].(bool)
	updated, _ := m["updated"].(float64)
	age := now.Sub(time.Unix(int64(updated), 0))
	m["up"] = running && updated > 0 && age < meshStale && age > -meshStale
	peers := 0
	if list, ok := m["peers"].([]any); ok {
		peers = len(list)
	}
	m["peers"] = peers
	if s, _ := m["npub"].(string); s == "" && boxNpub != "" {
		m["npub"] = boxNpub
	}
	return m
}

// Storage is GET /api/box/storage.
type Storage struct {
	// The screens' shape (api.js): the vault folder and its filesystem.
	Path  string `json:"path"`
	Used  uint64 `json:"used"`
	Free  uint64 `json:"free"`
	Total uint64 `json:"total"`

	VaultDir      string `json:"vaultDir"`
	DatabaseBytes uint64 `json:"databaseBytes"`
	BlossomBytes  uint64 `json:"blossomBytes"`
	BlobCount     int    `json:"blobCount"`
	OtherBytes    uint64 `json:"otherBytes"`
	Disk          Disk   `json:"disk"`
	MeasuredAt    int64  `json:"measuredAt"`
}

// StorageMeter walks the vault at most once per TTL: a Pi with a big
// Blossom folder should not walk it for every poll.
type StorageMeter struct {
	TTL time.Duration

	mu     sync.Mutex
	dir    string
	cached Storage
	at     time.Time
}

func (s *StorageMeter) Measure(vaultDir string) Storage {
	ttl := s.TTL
	if ttl == 0 {
		ttl = 30 * time.Second
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dir == vaultDir && time.Since(s.at) < ttl {
		return s.cached
	}
	st := Storage{VaultDir: vaultDir, MeasuredAt: time.Now().Unix()}
	st.Disk, _ = DiskOf(vaultDir)
	st.Path, st.Used, st.Free, st.Total = vaultDir, st.Disk.Used, st.Disk.Free, st.Disk.Total
	// The engine keeps its databases in db/ (DATABASE_PATH's data/ too, if used).
	dbDirs := []string{filepath.Join(vaultDir, "db"), filepath.Join(vaultDir, "data")}
	blobDir := filepath.Join(vaultDir, "blossom")
	_ = filepath.WalkDir(vaultDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		size := onDisk(info)
		switch {
		case within(p, dbDirs[0]) || within(p, dbDirs[1]):
			st.DatabaseBytes += size
		case within(p, blobDir):
			st.BlossomBytes += size
			st.BlobCount++
		default:
			st.OtherBytes += size
		}
		return nil
	})
	s.dir, s.cached, s.at = vaultDir, st, time.Now()
	return st
}

// onDisk is the space a file takes, not its length: a running Badger keeps
// its value logs as large sparse files (1 GiB+ each, a few KiB used).
func onDisk(info fs.FileInfo) uint64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Blocks) * 512
	}
	return uint64(info.Size())
}

func within(p, dir string) bool {
	rel, err := filepath.Rel(dir, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
