package main

import (
	"log/slog"
	"sync"
	"time"
)

// compactor is a store that can give disk back after deletes (Badger). LMDB
// reuses its freed pages, so its file stops growing but does not shrink.
//
// hold runs one step with every other write to the store held back (they
// wait, not fail).
type compactor interface {
	Compact(hold func(step func() error) error) error
}

// gatedCompactor is what compactAfterPrune calls: a gated store.
type gatedCompactor interface {
	Compact() error
}

// Compact compacts the store under the gate, so a close waits for it rather
// than freeing the store under a running compaction.
func (g *gatedDB) Compact() error {
	c, ok := g.inner.(compactor)
	if !ok {
		return nil
	}
	if !g.enter() {
		return errDBClosing
	}
	defer g.leave()
	return c.Compact(func(step func() error) error {
		g.writes.Lock()
		defer g.writes.Unlock()
		return step()
	})
}

// feedCompactEvery: the most often the feed cache is compacted. A prune runs
// every round (hourly); Flatten rewrites every table, which a phone should
// not do each hour.
const feedCompactEvery = 6 * time.Hour

var feedCompact struct {
	sync.Mutex
	last time.Time
}

// compactAfterPrune compacts db when a prune just deleted events from it and
// it was not compacted in the last feedCompactEvery. True when it ran.
func compactAfterPrune(db DBBackend, deleted int, now time.Time) bool {
	c, ok := db.(gatedCompactor)
	if !ok || deleted == 0 {
		return false
	}
	feedCompact.Lock()
	defer feedCompact.Unlock()
	if !feedCompact.last.IsZero() && now.Sub(feedCompact.last) < feedCompactEvery {
		return false
	}
	feedCompact.last = now
	start := time.Now()
	if err := c.Compact(); err != nil {
		slog.Warn("feed cache compaction failed", "err", err)
		return false
	}
	slog.Info("feed cache compacted", "after_deleting", deleted, "took", time.Since(start))
	return true
}
