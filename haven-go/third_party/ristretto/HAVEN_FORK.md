# ristretto v2.3.0, patched copy

This is `github.com/dgraph-io/ristretto/v2` v2.3.0 (Apache-2.0, see LICENSE), wired in with a
`replace` in `haven-go/go.mod`. Badger uses its `z` package to memory-map every database file.

Left out of the copy: `*_test.go`, `benchmarks/`, `contrib/`, `sim/`, and the upstream
`.github/` and `.gitignore`. Only the root, `z/` and `z/simd/` packages are kept (the ones
Badger imports).

Why a copy: on Linux, `z.mmap` mapped files with `unix.Mmap`, which records each mapping in
x/sys's global `mapper.active` map, keyed by a pointer to the mapping's last byte. `z.munmap`
and `z.mremap` use the raw syscalls, so that entry is never removed. Badger unmaps on every DB
close, memtable flush, compaction and vlog truncate. On Android (39-bit address space, Go's
randomized heap base) the Go heap later grows over a freed range, and the GC aborts the whole
app on the stale key: "found bad pointer in Go heap", "found pointer to free object", or
`index out of range` in `tryDeferToSpanScan`. Darwin is not affected: `z/mmap_darwin.go`
unmaps through `unix.Munmap`. Upstream issue: dgraph-io/ristretto#509, fix PR #510.

Changes from upstream are listed below. Keep every other file byte-identical to v2.3.0.

- `z/mmap_linux.go`: `mmap` maps with `unix.MmapPtr`, which registers nothing, so the raw
  `munmap`/`mremap` leave nothing stale. A size <= 0 returns `EINVAL`, as `unix.Mmap` did.

Drop this copy (remove the `replace` and this directory, then bump ristretto) once a release
contains ristretto #510 or another fix that keeps x/sys's mapping table in step.
