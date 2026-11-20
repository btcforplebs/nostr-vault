# badger v4.9.1, patched copy

This is `github.com/dgraph-io/badger/v4` v4.9.1 (Apache-2.0, see LICENSE), wired in with a
`replace` in `haven-go/go.mod`. It is the vault's store on every platform (Apple and Android
c-archive/c-shared builds, and the Linux engine built with `-tags nolmdb`).

Left out of the copy: `*_test.go`, the `badger/` command, `contrib/`, `docs/`, `images/`, and the
upstream `.github/`, `.trunk/`, `.vscode/`, `Makefile`, `test.sh`, `changes.sh`. Only the library
packages are kept.

Why a copy: each compactor goroutine polled on a 50 ms ticker forever. With 2 compactors per store
and 9 stores, an idle engine woke ~1,000 times a second and used ~2.9 % of a core doing nothing
(RESEARCH audit, finding L1).

Changes from upstream are listed below. Keep every other file byte-identical to v4.9.1.

- `levels.go`, `runCompactor`: a pass that finds work schedules the next one in 50 ms, as before;
  a pass that finds nothing sleeps 1 s. The Lmax-to-Lmax pass (off unless `LmaxCompaction`) runs
  every 10 s by clock instead of every 200th tick.
- `levels.go`, new `compactWake` channel and `wakeCompactors`: `addLevel0Table` wakes the
  compactors after it adds a table, and on every 10 ms check while a write is stalled on a full L0,
  so neither a flush nor a stalled write waits for the 1 s sleep.

Drop this copy (remove the `replace` and this directory) if upstream makes the compactor idle
interval configurable or event-driven.
