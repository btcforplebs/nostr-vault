package box

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Backup now, restore and restart on a box (One Vault spec E5). The engine's
// databases need it stopped to back up or restore (the Mac's BackupDatabaseC
// refuses while the relay runs too), so each is a job like a Move: stop the
// engine, run its own `backup -o` or `restore -i` (haven-go backup.go) with
// the same environment and folder, start it again, also on failure. One at
// a time, and never during a Move: a job holds the Mover's busy flag.
//
// Backups go in NV_DATA_DIR/backups, beside the box's own state and outside
// the vault folder, so a Move leaves them where they are. The newest
// backupsKept stay. A restore adds a backup's notes to the vault (the
// engine merges, never wipes), from a backup this box made.

const backupsKept = 5

var backupName = regexp.MustCompile(`^vault-\d{8}-\d{6}\.zip$`)

// EngineJob is the current or last backup, restore or restart.
type EngineJob struct {
	Kind     string `json:"kind"` // backup, restore, restart
	Name     string `json:"name,omitempty"`
	Phase    string `json:"phase"` // stopping, working, starting, done, failed
	Error    string `json:"error,omitempty"`
	Started  int64  `json:"startedAt"`
	Finished int64  `json:"finishedAt,omitempty"`
}

// BackupFile is one backup the box holds.
type BackupFile struct {
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	Created int64  `json:"createdAt"`
}

// ErrEngineBusy: a move, backup, restore or restart already has the engine.
var ErrEngineBusy = errors.New("the vault is busy: a move, backup, restore or restart is running; try again when it ends")

var engineJobs struct {
	mu   sync.Mutex
	last *EngineJob
}

// lastEngineJob is a copy of the current or last job, or nil.
func lastEngineJob() *EngineJob {
	engineJobs.mu.Lock()
	defer engineJobs.mu.Unlock()
	if engineJobs.last == nil {
		return nil
	}
	j := *engineJobs.last
	return &j
}

func setEngineJob(f func(j *EngineJob)) {
	engineJobs.mu.Lock()
	f(engineJobs.last)
	engineJobs.mu.Unlock()
}

// hold takes the Mover's busy flag for a job; false while a move or another
// job has it.
func (m *Mover) hold() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.busy {
		return false
	}
	m.busy = true
	return true
}

func (m *Mover) release() {
	m.mu.Lock()
	m.busy = false
	m.mu.Unlock()
}

// engineCommander runs the engine binary for one command on the vault: the
// production *Engine does; a test's fake runs a script.
type engineCommander interface {
	Command(args ...string) *exec.Cmd
}

// Command is the engine binary run with args in the vault folder with the
// engine's environment, its output in the box's log as the engine's own.
func (e *Engine) Command(args ...string) *exec.Cmd {
	dir := e.VaultDir()
	cmd := exec.Command(e.Bin, args...)
	cmd.Dir = dir
	cmd.Env = e.Env(dir)
	cmd.Stdout, cmd.Stderr = engineOutputs()
	return cmd
}

// backupsDir: NV_DATA_DIR/backups (BoxDir is NV_DATA_DIR/box).
func (m *Mover) backupsDir() string { return filepath.Join(filepath.Dir(m.BoxDir), "backups") }

// Backups lists the box's backups, newest first.
func (m *Mover) Backups() []BackupFile {
	entries, _ := os.ReadDir(m.backupsDir())
	out := []BackupFile{}
	for _, e := range entries {
		if !backupName.MatchString(e.Name()) || !e.Type().IsRegular() {
			continue
		}
		if info, err := e.Info(); err == nil {
			out = append(out, BackupFile{Name: e.Name(), Size: info.Size(), Created: info.ModTime().Unix()})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name > out[j].Name })
	return out
}

// runEngineJob stops the engine, runs work on the vault folder, and starts
// the engine again whatever work did, in the background.
func (m *Mover) runEngineJob(kind, name string, work func(vaultDir string) error) (*EngineJob, error) {
	if !m.hold() {
		return nil, ErrEngineBusy
	}
	engineJobs.mu.Lock()
	engineJobs.last = &EngineJob{Kind: kind, Name: name, Phase: "stopping", Started: time.Now().Unix()}
	engineJobs.mu.Unlock()
	dir := m.Engine.VaultDir()
	go func() {
		defer m.release()
		log.Printf("box: %s: stopping the engine", kind)
		m.Engine.Stop()
		setEngineJob(func(j *EngineJob) { j.Phase = "working" })
		err := error(nil)
		if work != nil {
			err = work(dir)
		}
		setEngineJob(func(j *EngineJob) { j.Phase = "starting" })
		if serr := m.Engine.Start(m.Ctx, dir); serr != nil && err == nil {
			err = fmt.Errorf("the engine didn't start again: %v", serr)
		}
		setEngineJob(func(j *EngineJob) {
			j.Finished = time.Now().Unix()
			if err != nil {
				j.Phase, j.Error = "failed", err.Error()
				log.Printf("box: %s failed: %v", kind, err)
				return
			}
			j.Phase = "done"
			log.Printf("box: %s done", kind)
		})
	}()
	return lastEngineJob(), nil
}

func (m *Mover) command(args ...string) (*exec.Cmd, error) {
	c, ok := m.Engine.(engineCommander)
	if !ok {
		return nil, errors.New("this box can't run the vault's own commands")
	}
	return c.Command(args...), nil
}

// BackupNow writes a new backup and keeps the newest backupsKept.
func (m *Mover) BackupNow(now time.Time) (*EngineJob, error) {
	name := "vault-" + now.UTC().Format("20060102-150405") + ".zip"
	dir := m.backupsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
		return nil, errors.New("a backup was made this second; try again")
	}
	return m.runEngineJob("backup", name, func(string) error {
		out := filepath.Join(dir, name)
		cmd, err := m.command("backup", "-o", out)
		if err != nil {
			return err
		}
		if err := cmd.Run(); err != nil {
			_ = os.Remove(out)
			return fmt.Errorf("the vault's backup didn't finish (%v); the box log says why", err)
		}
		if st, err := os.Stat(out); err != nil || st.Size() == 0 {
			_ = os.Remove(out)
			return errors.New("the vault's backup wrote nothing")
		}
		m.pruneBackups()
		return nil
	})
}

func (m *Mover) pruneBackups() {
	for _, b := range m.Backups()[min(len(m.Backups()), backupsKept):] {
		if err := os.Remove(filepath.Join(m.backupsDir(), b.Name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("box: removing old backup %s: %v", b.Name, err)
		}
	}
}

// Restore adds the notes in one of the box's backups to the vault.
func (m *Mover) Restore(name string) (*EngineJob, error) {
	name = strings.TrimSpace(name)
	if !backupName.MatchString(name) {
		return nil, errors.New("name must be one of this box's backups")
	}
	path := filepath.Join(m.backupsDir(), name)
	if st, err := os.Stat(path); err != nil || !st.Mode().IsRegular() {
		return nil, errors.New("no such backup on this box")
	}
	return m.runEngineJob("restore", name, func(string) error {
		cmd, err := m.command("restore", "-i", path)
		if err != nil {
			return err
		}
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("the vault's restore didn't finish (%v); the box log says why", err)
		}
		return nil
	})
}

// Restart stops the engine and starts it again (Force restart).
func (m *Mover) Restart() (*EngineJob, error) { return m.runEngineJob("restart", "", nil) }
