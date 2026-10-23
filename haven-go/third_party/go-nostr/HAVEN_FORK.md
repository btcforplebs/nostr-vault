# go-nostr v0.52.3, patched copy

This is `github.com/nbd-wtf/go-nostr` v0.52.3 (MIT, see LICENSE.md), wired in with a `replace`
in `haven-go/go.mod`. v0.52.3 is the final release of that module; upstream moved to
`fiatjaf.com/nostr`.

Left out of the copy: `*_test.go`, `example/`, `testdata/`, the upstream `.gitignore`, and the
libsecp256k1 bench, test and table-generator sources (none of them is built).

Why a copy: the `libsecp256k1` build tag makes signature checks 5.5x faster, but upstream's
`signature_libsecp256k1.go` decodes hex into fixed-size arrays without checking the length, so one
event with a long pubkey or sig panics. khatru checks signatures in a goroutine with no `recover`,
so in libhaven that panic kills the whole app. The fix has to live here because khatru calls
`Event.CheckSignature` itself.

Changes from upstream are listed below. Keep every other file byte-identical to v0.52.3.

- `signature_libsecp256k1.go`: `CheckSignature` rejects a pubkey that isn't 64 hex chars or a
  sig that isn't 128; `Sign` rejects a secret key that isn't 32 bytes.
