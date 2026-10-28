# khatru v0.19.1, patched copy

This is `github.com/fiatjaf/khatru` v0.19.1 (Unlicense, see LICENSE), wired in with a `replace`
in `haven-go/go.mod`. v0.19.1 is the final release of that module; upstream moved to
`fiatjaf.com/nostr/khatru`.

Left out of the copy: `*_test.go`, `docs/`, `examples/`, and the upstream `.gitignore`. Only the
root, `blossom/` and `policies/` packages are kept (the ones haven-go imports).

Why a copy: `notifyListeners` read the listener list with no lock while subscribe and unsubscribe
appended to it and swap-deleted entries. On a phone that restarts its relay on every return to
the foreground, many REQs open and close at once, and a torn read of a listener's filter is heap
corruption: the Go GC aborts the whole app with "found pointer to free object" (LogePhone,
2026-10-28). The fix has to live here because the list is private to khatru.

Changes from upstream are listed below. Keep every other file byte-identical to v0.19.1.

- `listener.go`: `notifyListeners` collects matching listeners under `clientsMutex` and writes
  to them after unlocking.

