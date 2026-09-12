# fips-bridge

An embedded FIPS (nostr-vpn's mesh) endpoint for Nostr Vault: no TUN device, no
DNS takeover, no NetworkExtension entitlement, so it can live inside a sandboxed
Mac app and an App Store iOS app.

```
crates/fips-bridge-core   the endpoint, the UDP/QUIC transport, the MTU budget
crates/fips-bridge-ffi    the C ABI the Swift side links against
crates/fips-bridge-probe  command-line probes: fips_serve, fips_fetch, mtu_probe, e2e
ios-probe/                a throwaway SwiftUI harness that links the static lib
```

This is a separate Cargo workspace. Nothing in `HavenApp.xcodeproj` references
it, so building the Mac or iOS app neither builds nor needs it.

**Android does consume it**, through the same C ABI:
`NostrVault/build_fips_android.sh` cross-compiles the cdylib into
`app/src/main/jniLibs/`, `FipsBridgeJNI.c` wraps it, and Settings -> Mesh turns
it on. The Rust artifact is gitignored and the CMake entry is conditional, so a
checkout without it still builds and the app reports the mesh as unavailable —
which also means a release can ship without the mesh if nobody runs the script.

`armeabi-v7a` does not build at all: `nvpn-fips-core` 0.4.72 assigns a `u32` to
`msg_namelen` (`upper/dns.rs:277`), which is `i32` on 32-bit Android. The app
ships `arm64-v8a` only, so this costs nothing today, and `x86_64` builds fine
for the emulator.

## The dependency pin, and why it keeps moving

`nvpn-fips-endpoint = "=0.4.72"`, exact, with `Cargo.lock` committed. Build with
`--locked`.

The upstream crate published 45 times on the 0.4 line, several times on some
days, and the 0.3 -> 0.4 boundary replaced the entire send/recv model. A caret
range here is a live hazard, not a convenience.

**The rename.** The package was renamed on 2026-08-25. `fips-endpoint` ends at
0.4.65 and `nvpn-fips-endpoint` begins at 0.4.65 the same day, same owner
(`mmalmi`), same version line. Only the *package* name changed: the crate still
declares `[lib] name = "fips_endpoint"`, so every `use fips_endpoint::` in this
workspace is unchanged and correct. A `fips-endpoint` release numbered 0.5.x is
**not** this line — do not follow it.

**To bump:** change the one version in the root `Cargo.toml`, run
`cargo test --workspace --locked` (it will tell you the lock is stale), then
`cargo update -p nvpn-fips-endpoint`, re-run the tests, and commit `Cargo.lock`
in the same commit. Read the diff of `endpoint.rs` upstream before believing a
patch release is a patch release.

**Blast radius by design.** `core/src/endpoint.rs` and
`core/src/transport/udp_socket.rs` are the only two files that touch
`fips_endpoint` directly. That is what keeps an upstream rename away from the C
ABI, let alone Swift.

## Gotchas that have already cost time

**`local_rendezvous` is ours, not the builder's.** `bind_endpoint` hands the
builder a fully-formed `Config` instead of using its `discovery_scope` shortcut.
The shortcut calls `apply_default_scoped_discovery` (nvpn-fips-core 0.4.72,
`src/endpoint.rs:185`), which sets `node.discovery.local.enabled = true`
unconditionally whenever no transport was configured — so the flag was a no-op
and every endpoint joined host-wide loopback rendezvous on
`127.0.0.1:21211` regardless. That both collides with a co-installed nostr-vpn
and lets an off-LAN test pair over loopback and pass for a reason it is not
measuring. `endpoint_config` reproduces the upstream profile field for field and
changes exactly one thing; four tests in `endpoint.rs` hold that line.

**The MTU budget is 1170, not 1200.** At the default underlay MTU of 1280, FIPS
overhead is 110, so a 1200-byte QUIC packet costs two fragments by construction.
A single-fragment 1200 needs an underlay of at least 1310. See
`core/src/transport/mtu.rs` and its tests. FIPS reassembles up to 128 fragments,
so a probe that keys its verdict on "largest delivered >= 1200" passes with the
1200 rung lost.

**Two NAT'd nodes cannot peer on their own — hence the seeds.** NAT-traversal offers ride an
authenticated FIPS session; they are not Nostr events. With no shared reachable
FIPS node, the offer never crosses — proved on 2026-09-03 between a home NAT and
a phone hotspot, with both adverts present on the relays the whole time. Raw UDP
hole punching between the same two hosts worked, so the missing piece is
signaling, not the NATs. nostr-vpn's own answer is two hard-coded public transit
seeds (`DEFAULT_FIPS_BOOTSTRAP_PEERS`). Same-host smoke tests cannot exercise
any of this.

`endpoint.rs` now ships `PUBLIC_MESH_SEEDS`, the FIPS public test mesh, dialled
as auto-connect peers by `EndpointOptions::with_identity` (and *not* by
`ephemeral`, which the in-process probes use). They are the ones
`jmcorgan/fips-initramfs` ships as its defaults, each with a hostname at
priority 10 and a literal address at priority 20: the name survives the node
moving, the address survives DNS being unavailable, and neither alone survives
both.

Reaching a seed is necessary and not sufficient. On 2026-09-08 the Android app
connected to both (39 ms and 52 ms) from behind a home NAT, and that says
nothing yet about whether two NAT'd nodes can reach *each other* through them —
on 2026-09-03 nostr-vpn's own seeds were reachable too and the peering still
failed. The hotspot gate is what decides it.

## Tests

`cargo test --workspace --locked` — 8 unit tests, no network, no sockets.
Everything else in here is a probe you run by hand against a second host.
