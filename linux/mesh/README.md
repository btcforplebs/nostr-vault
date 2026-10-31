# nv-mesh: the FIPS mesh in nostr-vault-linux

`nv-mesh` runs the mesh engine the Mac app runs (`fips-v2-android`, lib `nvfips`) as its own process in
the `nostr-vault-linux` container, next to havend. It uses the Mac's start options
(`MeshDevices.swift` `macEngineOptions`):

- **Own devices** (the owner's devices listed in `mesh-devices.json`) reach havend on `NV_PORT`, uncapped.
  Only they get answers to traversal offers, so only they learn the box's LAN or public address.
  Each one is dialed at start.
- **Strangers** reach the box only through the public seeds, capped (1 MiB/s, 16 slots). They get
  havend's mesh door on `NV_MESH_DOOR_PORT`, never `NV_PORT`. That is the same split the Mac has
  between relayPort and meshPlainPort.
- **No devices, no engine.** An empty list would leave the node open to anyone, so `nv-mesh` waits.
- **The box's mesh key is its own.** It is made on first boot. It is never the owner's key, and no
  nsec of the owner's is on the box.

## Files and uids

`nv-mesh` runs as **its own uid** (10001 `nvmesh` in the image). That uid is never root and never
havend's: havend faces the internet and shares the data dir, so if it ran as the same uid it could
read the key. nv-mesh refuses to start as root. The engine's TUN runs in-process, so it needs no
capabilities.

| Path | Owner | Mode | What |
|------|-------|------|------|
| `mesh/` | nv-mesh | 0755 | |
| `mesh/key/nsec` | nv-mesh | dir 0700, file 0600 | The box's mesh key, made on first boot. It is linked into place, never renamed over an existing key, and the directory is fsynced, so a power cut or two racing starts can't change the npub. nv-mesh refuses to use a key that is a symlink, belongs to another uid, can't be made 0600, or doesn't decode, and never replaces such a key. No API may ever serve it. |
| `mesh/npub` | nv-mesh | 0644 | The box's mesh npub. The owner adds it under My Devices on the phone. |
| `mesh/status.json` | nv-mesh | 0644 | Written every 5 s. It holds the engine's `NvFipsStatusJSON` plus `npub`, `devices` (count), `error` (plain words, or null) and `updated` (unix s). It is written atomically. havend returns it as `mesh` in `GET /api/box/status`. |
| `mesh-devices.json` (`NV_MESH_DEVICES`) | havend | readable by nv-mesh | The owner's devices: `["npub1…"]`, `[{"npub":"npub1…","name":"…"}]` or `{"devices":[…]}`. It is re-read every 5 s, and a change restarts the engine (as on the Mac), so a removed device drops at once. If the file is unreadable, the last good list is kept. Bad npubs and the box's own npub are skipped. |

## Environment

| Var | Default | |
|-----|---------|---|
| `NV_DATA_DIR` | `/data` | |
| `NV_PORT` | `8080` | havend's port. Own devices get it. |
| `NV_MESH_DOOR_PORT` | `NV_PORT+1` (8081) | havend's mesh door, loopback only. It must equal havend's `HAVEN_MESH_PLAIN_PORT`. |
| `NV_MESH_UDP_PORT` | `0` (OS picks) | The mesh UDP port. Set it if the container publishes a port instead of using host networking. |
| `NV_MESH_DEVICES` | `$NV_DATA_DIR/mesh-devices.json` | |
| `NV_MESH_RELAYS` | the Mac's finder relays | Comma list. Phones find the box on the same relays the Mac uses, so leave it unset. |
| `RUST_LOG` | `info,nostr_relay_pool=warn` | |

## What the other lanes need

- **havend (haven-go/cmd/havend):**
  - Open the mesh door at start: set `HAVEN_MESH_PLAIN_PORT=8081` and serve the door
    (`setMeshServing(true)`). On the Mac, `SetMeshServingC(1)` does this.
  - Mesh traffic reaches 8080 and 8081 from 127.0.0.1. Never treat loopback as the owner: keep owner
    rights on NIP-98/NIP-42.
  - `GET /api/box/devices` reads `mesh-devices.json` (and the box npub from `mesh/npub`). Writing
    it (atomically) is how the owner approves a device.
  - Backups of `NV_DATA_DIR` (`ZipDirectory` copies the whole dir) must skip `mesh/key/`. Running
    as another uid, havend can't read it anyway, so expect a read error there. A box restored from a
    backup makes a new npub, and the owner approves it again.
  - `POST move` stays on the same box, so the key must go with it, keeping uid 10001 and the 0700
    mode. Otherwise every device loses the box. Do the move from the supervisor or the installer,
    which can carry `mesh/key/`, not with havend's copy.
  - `GET status` gets its `mesh` field from `status.json`.
  - `POST move` needs nv-mesh restarted on the new `NV_DATA_DIR`.
- **Container (linux/ outside mesh/):**
  - Run `nv-mesh` as a second supervised process, under its own uid (not havend's, not root). The
    data dir must let that uid create `mesh/`, and let havend's uid write `mesh-devices.json`.
  - Copy `/out/nv-mesh` from this Dockerfile's `build` stage, and install `libnftnl11 libmnl0
    libdbus-1-3 ca-certificates` (Debian bookworm names).
  - Use `network_mode: host` on the Pi. Then the LAN candidate that own devices get is the Pi's real
    LAN address, and a phone on the same Wi-Fi links directly with no router hairpin. In bridge mode
    the offered address is the docker bridge IP, which phones can't reach.
  - Port 0 avoids clashing with the nvpn/FIPS that sovereign-dns already runs on the Pi.

## Build

```sh
# from the repo root
docker buildx build -f linux/mesh/Dockerfile --platform linux/arm64,linux/amd64 --target build .
# stand-alone test image
docker buildx build -f linux/mesh/Dockerfile --platform linux/arm64 --target runtime -t nv-mesh --load .
```

The build changes nothing in `fips-v2`, `fips-v2-android` or `fips-bridge`. It reads `fips-v2/src/stack.rs`,
`fips-v2-android` and `web-relay-vault` by path, with `Cargo.lock` copied from `fips-v2-android`, so
both use the same fips rev (`e831d6d5`).

## Link test (throwaway keys, no owner key)

The test runs the box and a peer on one docker network. It uses
`fipsv2-probe connect --peer <box npub> --lan --relay <the three finder relays>`, plus a stand-in
HTTP server on 127.0.0.1:8080/8081 inside the box's network namespace:

1. The box starts with no `mesh-devices.json`. `status.json` shows `running:false` and says to add a device.
2. Write the peer's npub to `mesh-devices.json`. Within 5 s the engine starts and shares 8080.
3. The peer links directly: NAT traversal uses the box's LAN candidate, then an XK session.
   `curl` through the peer returns the box's 8080.
4. A second peer that is not in `mesh-devices.json` gets no answer to its offers and never reaches 8080.
