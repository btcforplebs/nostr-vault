package box

import (
	"context"
	"errors"
	"log"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Engine runs the vault engine as a child process and restarts it when it
// exits on its own. Stop/Start bracket a vault move: while stopped, nothing
// has the vault's databases open.
type Engine struct {
	Bin      string
	Env      func(vaultDir string) []string
	Prepare  func(vaultDir string) error // writes the engine's files before each start
	StopWait time.Duration               // SIGTERM grace before SIGKILL

	mu       sync.Mutex
	vaultDir string
	cmd      *exec.Cmd
	done     chan struct{} // closed when the current child has exited
	wanted   bool          // restart on exit
	started  time.Time
	restarts int
	gen      int // bumped by each Start; an older watch loop sees it and quits
}

// EngineState is what status reports about the engine.
type EngineState struct {
	Running  bool   `json:"running"`
	Pid      int    `json:"pid,omitempty"`
	Uptime   int64  `json:"uptimeSeconds,omitempty"`
	Restarts int    `json:"restarts"`
	VaultDir string `json:"vaultDir"`
}

func (e *Engine) State() EngineState {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := EngineState{Restarts: e.restarts, VaultDir: e.vaultDir}
	if e.cmd != nil && e.cmd.Process != nil {
		s.Running = true
		s.Pid = e.cmd.Process.Pid
		s.Uptime = int64(time.Since(e.started).Seconds())
	}
	return s
}

// VaultDir is where the engine runs (or last ran).
func (e *Engine) VaultDir() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.vaultDir
}

// Start runs the engine on vaultDir and keeps it running until Stop or ctx ends.
func (e *Engine) Start(ctx context.Context, vaultDir string) error {
	e.mu.Lock()
	if e.wanted {
		e.mu.Unlock()
		return errors.New("engine already running")
	}
	e.wanted = true
	e.vaultDir = vaultDir
	e.gen++
	gen := e.gen
	e.mu.Unlock()
	if err := e.spawn(); err != nil {
		e.mu.Lock()
		e.wanted = false
		e.mu.Unlock()
		return err
	}
	go e.watch(ctx, gen)
	return nil
}

func (e *Engine) spawn() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.Prepare != nil {
		if err := e.Prepare(e.vaultDir); err != nil {
			return err
		}
	}
	cmd := exec.Command(e.Bin)
	cmd.Dir = e.vaultDir
	cmd.Env = e.Env(e.vaultDir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan struct{})
	e.cmd, e.done, e.started = cmd, done, time.Now()
	go func() {
		_ = cmd.Wait()
		e.mu.Lock()
		if e.cmd == cmd {
			e.cmd = nil
		}
		e.mu.Unlock()
		close(done)
	}()
	log.Printf("box: engine started (pid %d) in %s", cmd.Process.Pid, e.vaultDir)
	return nil
}

// watch restarts the child when it exits while still wanted, backing off
// from 1s to 1m so a crash loop does not spin.
func (e *Engine) watch(ctx context.Context, gen int) {
	backoff := time.Second
	for {
		e.mu.Lock()
		done := e.done
		e.mu.Unlock()
		select {
		case <-ctx.Done():
			e.mu.Lock()
			mine := e.gen == gen
			e.mu.Unlock()
			if mine {
				e.Stop()
			}
			return
		case <-done:
		}
		e.mu.Lock()
		wanted := e.wanted && e.gen == gen
		ran := time.Since(e.started)
		e.mu.Unlock()
		if !wanted {
			return
		}
		if ran > 5*time.Minute {
			backoff = time.Second
		}
		log.Printf("box: engine exited after %s; restarting in %s", ran.Round(time.Second), backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		e.mu.Lock()
		if !e.wanted || e.gen != gen { // stopped (or restarted) during the backoff
			e.mu.Unlock()
			return
		}
		e.restarts++
		e.mu.Unlock()
		if err := e.spawn(); err != nil {
			log.Printf("box: engine restart failed: %v", err)
			e.mu.Lock()
			// Leave a closed done so the loop tries again after the next backoff.
			d := make(chan struct{})
			close(d)
			e.done = d
			e.mu.Unlock()
		}
		if backoff *= 2; backoff > time.Minute {
			backoff = time.Minute
		}
	}
}

// Stop ends the engine and waits for it to exit (SIGTERM, then SIGKILL).
func (e *Engine) Stop() {
	e.mu.Lock()
	e.wanted = false
	cmd, done := e.cmd, e.done
	e.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	wait := e.StopWait
	if wait == 0 {
		wait = 20 * time.Second
	}
	select {
	case <-done:
	case <-time.After(wait):
		log.Printf("box: engine did not stop in %s; killing it", wait)
		_ = cmd.Process.Kill()
		<-done
	}
}
