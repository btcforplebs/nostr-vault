package box

import (
	"context"
	"errors"
	"log"
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
	gen      int  // bumped by each Start; an older watch loop sees it and quits
	reload   bool // the current child was stopped by Reload: respawn at once
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
	e.reload = false
	e.vaultDir = vaultDir
	e.gen++
	gen := e.gen
	e.mu.Unlock()
	if err := e.spawn(gen); err != nil {
		e.mu.Lock()
		e.wanted = false
		e.mu.Unlock()
		return err
	}
	go e.watch(ctx, gen)
	return nil
}

// errNotWanted: spawn was asked for by a Start or watch loop that is no
// longer current (a Stop, or a Stop then Start, came in between).
var errNotWanted = errors.New("engine stopped or restarted; not spawning")

// spawn starts a child for generation gen. It checks under the same lock it
// starts the child with that the engine is still wanted at that generation:
// a Stop (a Move) landing after the caller's own check must win, or Stop sees
// no child, returns, and a child opens the vault the Move is copying.
func (e *Engine) spawn(gen int) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.wanted || e.gen != gen {
		return errNotWanted
	}
	if e.Prepare != nil {
		if err := e.Prepare(e.vaultDir); err != nil {
			return err
		}
	}
	cmd := exec.Command(e.Bin)
	cmd.Dir = e.vaultDir
	cmd.Env = e.Env(e.vaultDir)
	// Still to havend's own output, and into the box's log (routes_logs.go).
	cmd.Stdout, cmd.Stderr = engineOutputs()
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
		reload := e.reload
		e.reload = false
		e.mu.Unlock()
		if !wanted {
			return
		}
		if reload {
			// Asked for (Reload), not a crash: no backoff, no restart count.
			if err := e.spawn(gen); err != nil {
				if errors.Is(err, errNotWanted) {
					return
				}
				log.Printf("box: engine reload failed: %v", err)
				e.mu.Lock()
				d := make(chan struct{})
				close(d)
				e.done = d
				e.mu.Unlock()
			}
			continue
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
		if err := e.spawn(gen); err != nil {
			if errors.Is(err, errNotWanted) {
				return
			}
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

// Reload restarts a running engine so it reads its files again: Prepare runs
// before the new child starts. It returns at once; the watch loop respawns
// the child when the old one has exited. A stopped engine (during a Move)
// is left stopped and reports false: its next Start runs Prepare anyway.
// Unlike Stop then Start, it never starts an engine a Move stopped: spawn
// re-checks wanted and the generation under its own lock.
func (e *Engine) Reload() bool {
	e.mu.Lock()
	cmd, done := e.cmd, e.done
	if !e.wanted || cmd == nil || cmd.Process == nil {
		e.mu.Unlock()
		return false
	}
	e.reload = true
	wait := e.StopWait
	e.mu.Unlock()
	if wait == 0 {
		wait = 20 * time.Second
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	go func() {
		select {
		case <-done:
		case <-time.After(wait):
			log.Printf("box: engine did not stop for a reload in %s; killing it", wait)
			_ = cmd.Process.Kill()
		}
	}()
	return true
}

// Stop ends the engine and waits for it to exit (SIGTERM, then SIGKILL).
func (e *Engine) Stop() {
	e.mu.Lock()
	e.wanted = false
	e.reload = false
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
