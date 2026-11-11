# The `fips-bridge` Crate

**How the FIPS mesh gets into the Swift and Kotlin apps.**

*Rewritten 2026-07-27. The May 2026 version proposed a `fips-haven-ffi` crate wrapping
`fips-endpoint` 0.3.16 with a `tcp_forwards` config and an upstream request for
`fips_endpoint_dial_tcp`. None of that applies: 0.4.x replaced the entire send/recv model with
ports and services, there is no TCP forwarding in the API, and none is coming. Architecture
context is in `FIPS_INTEGRATION_ROADMAP.md`; this document is the crate itself.*

---

## 1. The rule that governs the design

**The FFI is never on the per-packet path.**

Video at 8 Mbps in ~1200-byte payloads is roughly 830 datagrams/sec in each direction.
Crossing the Swift or Kotlin boundary per packet — ARC traffic on one side, a JNI
`GetByteArrayElements` allocating a Java array per packet straight into GC pressure on the
other — would be fatal to both throughput and battery.

So the **entire dataplane lives in Rust**: the loopback listeners, quinn, the FIPS pump loop,
the peer table, the port map. Swift and Kotlin call about eight control-plane functions, all
at human timescales.

This has a second benefit. Because the host apps never touch `fips-endpoint` types, the churn
in that crate (45 releases on the 0.4 line, one on the day this was written) is absorbed in
two Rust files and never reaches the app.

**Poll, don't call back.** Callbacks from Rust threads need `@convention(c)` trampolines and
careful lifetime management on Swift, and `AttachCurrentThread`/`DetachCurrentThread` plus
global refs on Android. Polling costs one JSON serialization per second, removes that entire
bug class, and matches the 5-second `Timer` shape already used by `FIPSDetectionService.swift`.

---

## 2. Layout

```
fips-bridge/
├── Cargo.toml                    # workspace; fips-endpoint pinned "=0.4.45"
├── Cargo.lock                    # COMMITTED
├── rust-toolchain.toml           # stable, pinned
├── .cargo/config.toml            # vendored-sources replacement
├── vendor/                       # cargo vendor output
└── crates/
    ├── fips-bridge-core/         # rlib — all logic, no FFI
    │   └── src/
    │       ├── lib.rs
    │       ├── config.rs         # serde BridgeConfig <- JSON from the host
    │       ├── runtime.rs        # tokio runtime, start/stop, task supervision
    │       ├── endpoint.rs       # FipsEndpoint bind/shutdown, .config() assembly
    │       ├── transport/
    │       │   ├── udp_socket.rs # AsyncUdpSocket over fips-endpoint  <- core risk
    │       │   ├── addr_map.rs   # SocketAddr <-> PeerIdentity bimap
    │       │   └── tls.rs        # self-signed cert + npub-pinned verifier
    │       ├── proxy/
    │       │   ├── ingress.rs    # loopback TCP listener -> QUIC bidi stream
    │       │   ├── egress.rs     # QUIC bidi stream -> 127.0.0.1:relayPort
    │       │   └── portmap.rs    # persisted npub -> loopback port assignment
    │       ├── status.rs         # serde snapshot the host polls
    │       └── error.rs
    ├── fips-bridge-ffi/          # staticlib + cdylib — the C ABI
    ├── fips-bridge-probe/        # Phase 0a measurement binary
    └── fips-bridge-tests/        # two endpoints, no app
```

`fips-endpoint` is touched in exactly two files — `endpoint.rs` and `transport/udp_socket.rs`.
When 0.4.46 renames something, those are the only files that move.

---

## 3. C ABI

Mirrors the existing Go FFI conventions from `libhaven.h` — `char*` in and out, caller frees,
`int` status codes — so both bridging headers and the JNI shim stay uniform in style.

```c
int   FipsBridgeStart(const char* config_json);   // nsec, relay port, mode, mtu, data dir
void  FipsBridgeStop(void);

char* FipsBridgeStatusJSON(void);                 // state, npub, peers, relays, counters
char* FipsBridgeLoopbackOrigin(const char* npub, uint16_t remote_port);

int   FipsBridgeIngestNostrEvent(const char* event_json);
int   FipsBridgeUpdateRelays(const char* relays_json);

void  FipsBridgeFreeString(char* ptr);
```

`FipsBridgeLoopbackOrigin` is idempotent: it allocates a listener the first time it sees an
npub and returns the persisted port thereafter, e.g. `"http://127.0.0.1:54312"`. It returns
NULL when the bridge is not running, which the callers treat as "leave the URL alone".

`FipsBridgeIngestNostrEvent` matters more than it looks. `fips-endpoint` exposes
`ingest_nostr_event`, and feeding it from the app's existing `NostrService` relay connections
avoids Rust opening a **second** set of websockets to the same relays — which would double
connection count and battery, and make the relay-status UI lie. Add kind 37195 to an existing
filter and forward.

Every export is wrapped in `std::panic::catch_unwind`, returning NULL or a negative int on
panic, matching the existing null-on-error convention. Unwinding stays enabled for the FFI
crate specifically, since `catch_unwind` depends on it.

Config JSON:

```json
{
  "identity_nsec": "nsec1...",
  "mode": "both",
  "relay_port": 3355,
  "udp_mtu": 1400,
  "discovery_relays": ["wss://relay.damus.io"],
  "discovery_scope": "nostr-vault",
  "data_dir": "/path/to/app/support"
}
```

`mode` is `"serve"`, `"consume"`, or `"both"` — the mechanism behind the platform roles.
iOS runs `"consume"` by default and `"both"` only in kiosk mode.

---

## 4. Android reuses the same C ABI

`NostrVault/app/src/main/java/com/nostrvault/relay/HavenBridgeJNI.c` already converts
`jstring`→`char*` for the Go exports. Mirror it as `fips/FipsBridgeJNI.c`.

That gives one FFI surface across all three platforms, no `jni` crate dependency, and no
`AttachCurrentThread` anywhere — because polling means there are no callbacks.

Build `fips-bridge-ffi` as a `cdylib` → `libfips_bridge.so` per ABI, alongside the existing
`libhaven.so` in `app/src/main/jniLibs/<abi>/`.

Route Rust logs through `android_logger` under `#[cfg(target_os = "android")]` rather than
relying on the stderr-pipe trick in `HavenBridgeJNI.c` — that pipe is process-wide, so
depending on it would make correctness a function of library init order.

---

## 5. Tokio alongside the Go runtime

They coexist: separate thread pools, separate schedulers, no shared state. Build with
`worker_threads(2)`; the dataplane is I/O-bound, not CPU-bound.

Two hazards worth naming:

- **Go's `SIGURG` async-preemption signals** land on Rust threads too and surface as `EINTR`
  from blocking syscalls. std and mio retry where it matters, so this is a non-issue in
  practice — but it explains otherwise-mysterious spurious wakeups.
- **`blocking_*` variants must not be called from inside a tokio runtime.** `fips-core`'s own
  docs say so explicitly. Use only the async forms, even where the blocking one reads more
  simply.

The runtime is held in a `static OnceLock<Mutex<Option<BridgeHandle>>>`. `FipsBridgeStart`
builds it and blocks on `bind()`; `FipsBridgeStop` signals shutdown, awaits
`endpoint.shutdown()`, and drops the runtime under a timeout so a wedged task cannot block app
termination.

---

## 6. Build integration

Mirrors the existing Go build scripts exactly, including their incrementality tricks.

| Script | Output | Mirrors |
|---|---|---|
| `HavenApp/HavenApp/App/build_fips.sh` | `HavenApp/build/libfips.a` (universal via `lipo`) | `build_haven.sh` — sha256 checksum skip-logic |
| `HavenApp/HavenApp/App/build_fips_ios.sh` | `HavenApp/build/ios/libfips_ios.a` | `build_haven_ios.sh` — including the device↔simulator platform marker |
| `NostrVault/build_fips_android.sh` | `app/src/main/jniLibs/<abi>/libfips_bridge.so` | `build_haven_android.sh` — bash 3.2 safe, **no `declare -A`** |

That last constraint is not pedantry: `build_haven_android.sh` "had never worked" until commit
`ba628e0` fixed exactly this class of problem. Do not reintroduce it.

Xcode wiring follows the Go pattern: a `PBXShellScriptBuildPhase` ordered before `Sources`,
the `.a` linked as an explicit `PBXFileReference` + `PBXBuildFile` in the Frameworks phase, and
a `#include` of the cbindgen-generated header in both bridging headers. `HEADER_SEARCH_PATHS`
and `LIBRARY_SEARCH_PATHS` already cover `build/` and `build/ios/`, so no settings change is
needed provided the outputs land there.

Required targets:

```
aarch64-apple-darwin  x86_64-apple-darwin        # macOS universal
aarch64-apple-ios     aarch64-apple-ios-sim      # iOS device + simulator
aarch64-linux-android x86_64-linux-android       # Android (armv7 optional — see below)
```

**All six verified building as of 2026-07-27**, `fips-bridge-core` with quinn + rustls + ring.
Two gotchas cost real time and are worth writing down:

**Targets are per-toolchain.** The iOS and Android targets were installed against *nightly*,
but `rust-toolchain.toml` pins stable — so every cross-build failed with `can't find crate for
core` on trivial crates like `memchr` and `log`. That reads like a code problem and isn't.

```bash
rustup target add --toolchain stable \
  x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
  aarch64-linux-android x86_64-linux-android
```

**`ring` needs NDK clang for Android**, and cc-rs will not find it on its own — it looks for a
bare `aarch64-linux-android-clang` that does not exist. `build_fips_android.sh` must export,
per ABI (API 26, matching `build_haven_android.sh`):

```bash
NDK=$ANDROID_NDK_HOME
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
export CC_aarch64_linux_android=$BIN/aarch64-linux-android26-clang
export AR_aarch64_linux_android=$BIN/llvm-ar
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$BIN/aarch64-linux-android26-clang
```

Apple targets need no such setup — `ring` cross-compiles to iOS device and simulator with no
configuration at all, which was the outcome most in doubt.

Consider dropping `armeabi-v7a` for the FIPS library specifically — 32-bit Android is
negligible in 2026 and it is the riskiest remaining cross-build target.

Release profile: `lto = "thin"`, `codegen-units = 1`, `strip = true`. Expect +2–4 MB per
architecture on top of `libhaven.a`.

---

## 7. Verification

**Phase 0a (no app):**

- `fips-bridge-probe` — measures the datagram ceiling. Current result on 0.4.45: API accepts
  up to **65,525 bytes**, rejects 65,526 with `ServiceDatagramTooLarge`, matching
  `fsp_service_datagram_max_body_len()`. Two in-process endpoints peer on the first canary via
  `local_rendezvous()` + `without_system_tun()`.
  *In-process cannot fragment, so this proves the API surface and the ceiling — not the
  single-fragment limit. That needs the two-host run.*
- `quic_e2e` — **PASSING.** Stands up two embedded endpoints, runs quinn over the custom
  `AsyncUdpSocket`, and streams 20 MiB across a bidirectional QUIC stream: 20,971,520 bytes
  in and out, sha256 identical on the sender, the receiver's own computation, and the digest
  echoed back. 111 MiB/s in-process.
  *This is the load-bearing result — QUIC does ride on FIPS service datagrams, so the
  loopback-proxy design stands. The throughput figure is an upper bound with no
  fragmentation, no loss and no RTT; treat it as "the plumbing works", not as a prediction.*
- `http_e2e` — **PASSING, and this is the product mechanism.** A real HTTP origin on loopback
  (standing in for the Go relay + Blossom, which share one port) exported over the mesh and
  re-exposed on a different loopback port. All three checks pass:
  full GET (200, 4 MiB, sha256 identical), byte range (`206` with correct `Content-Range`,
  bytes identical to the source slice), and `101 Switching Protocols` with bidirectional
  traffic *after* the upgrade — the relay's WSS path.
  Independently confirmed with **curl** as an external client:
  `curl http://127.0.0.1:18080/blob | shasum -a 256` matched the origin digest exactly, and a
  range request returned `Content-Range: bytes 100-199/4194304`.
  *This is the evidence for the loopback proxy over a `URLProtocol` shim: if curl cannot tell
  the difference, neither can AsyncImage, AVURLAsset, Coil or ExoPlayer.*
- **Loss recovery** via `FIPS_BRIDGE_LOSS_PERMILLE` (synthetic outbound drop in the
  `AsyncUdpSocket`). 20 MiB transferred intact at 0/1/3/5/10% loss:

  | loss | result | throughput |
  |---|---|---|
  | 0% | PASS | 115.8 MiB/s |
  | 1% | PASS | 106.6 MiB/s |
  | 3% | PASS | 102.0 MiB/s |
  | 5% | PASS | 111.5 MiB/s |
  | 10% | PASS | 102.3 MiB/s |

  *Read this narrowly. It proves loss is surfaced to quinn correctly, that recovery works over
  FIPS datagrams, and that the backpressure path does not deadlock under drops. It says
  almost nothing about throughput under real loss, because in-process RTT is ~0 and
  retransmit cost is dominated by RTT. On a 50 ms cellular path, 3% loss will hurt far more
  than this table suggests.*
- **All six cross-compile targets building** (see §6 for the two gotchas).

Still outstanding, and the real gate:

- `mtu_probe` across two hosts — the number that actually decides the transport. Must show
  >1200 bytes surviving unfragmented.
- `loopback_e2e` across two hosts on different networks, both behind NAT.
- Throughput at 0/1/3/5% injected loss — the case where FIPS's all-or-nothing reassembly
  bites, and the one that in-process testing structurally cannot reveal.

**Per phase thereafter:**

- `lipo -info` shows a universal library.
- `curl -v http://127.0.0.1:<port>/<sha256>` returns the blob with the correct `Content-Type`
  — proving the Go blob regex sees an untouched path.
- `curl -H "Range: bytes=0-1023"` returns `206` — proving byte-transparency.
- `websocat ws://127.0.0.1:<port>` accepts a NIP-01 `REQ` — proving the relay scope and the
  `101` upgrade.
- Blobs actually land in the disk cache — the `isLocalURL` check from the roadmap's §4.3.

---

## 8. Open items

- `AsyncUdpSocket` over FIPS datagrams is the one genuinely novel piece. `iroh` has solved
  QUIC-over-a-non-UDP-path in production and is worth reading before writing our own, though
  its dependency tree is heavy enough that we would only adopt it if the custom socket proves
  harder than expected.
- Vendoring (`cargo vendor` + `.cargo/config.toml`) is specified but not yet done. Until it
  is, a yanked or changed upstream can break release builds.
- The two-host probe run is pending; every throughput figure in this document is unmeasured
  until it happens.
