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
- `relay.go`, `handlers.go`, `listener.go`: `Relay.ReqCaps`. If set, each REQ is checked once,
  before any filter runs: at most `maxFilters` filters, and the connection's open listeners (one per
  filter, `"limit":0` included, a REQ on an open id adding to them) plus listeners reserved by REQs
  still in flight plus this REQ's filters at most `maxListeners`. Counted and reserved under
  `clientsMutex` (`reserveListeners`/`releaseReserved`), so a burst of REQs on one connection
  cannot pass it. A refused REQ gets CLOSED. `ListenerCount(ws)` for tests. Used by the mesh door
  (haven-go `mesh_query_caps.go`).
- `responding.go`: the `RejectFilter` hooks run before the `"limit":0` (live-only) return. Upstream
  returned first, so a live-only REQ skipped every read gate and got new events on `/private` and
  `/chat` with no AUTH (Tron, #1966). An empty live-only filter is now refused where empty filters
  are.
- `handlers.go`: a REQ refused part-way (one of its filters rejected) also removes the listeners its
  earlier filters opened. Upstream kept them: the client got CLOSED and sends no CLOSE, so they held
  places under `ReqCaps` until it reconnected (Tron, #1963).
