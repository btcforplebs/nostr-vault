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
	Version string          `json:"version"`
	Uptime  int64           `json:"uptime"` // seconds since havend started
	Mem     Mem             `json:"mem"`
	Disk    Disk            `json:"disk"`
	Mesh    json.RawMessage `json:"mesh"`
	Engine  EngineState     `json:"engine"`
	Owner   string          `json:"owner"`
	Device  string          `json:"device"` // the box's own npub
	Move    *MoveState      `json:"move,omitempty"`
}

// readMesh returns the mesh process's status file as-is, or
// {"running":false} when there is none or it is not JSON.
func readMesh(path string) json.RawMessage {
	b, err := os.ReadFile(path)
	if err != nil || len(b) > 64<<10 || !json.Valid(b) {
		return json.RawMessage(`{"running":false}`)
	}
	return json.RawMessage(b)
}

// Storage is GET /api/box/storage.
type Storage struct {
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
