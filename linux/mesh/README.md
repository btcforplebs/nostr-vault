# nv-mesh: the FIPS mesh in nostr-vault-linux

`nv-mesh` runs the mesh engine the Mac app runs (`fips-v2-android`, lib `nvfips`) as its own process in
the `nostr-vault-linux` container, next to havend. It uses the Mac's start options
(`MeshDevices.swift` `macEngineOptions`):

- **Own devices** (the owner's devices listed in `devices.json`) reach havend on `NV_PORT`, uncapped.
  Only they get answers to traversal offers, so only they learn the box's LAN or public address.
  Each one is dialed at start.
- **Strangers** reach the box only through the public seeds, capped (1 MiB/s, 16 slots). They get
  havend's mesh door on `NV_MESH_DOOR_PORT`, never `NV_PORT`. That is the same split the Mac has
  between relayPort and meshPlainPort.
- **No devices, no engine.** An empty list would leave the node open to anyone, so `nv-mesh` waits.
- **The box's mesh key is its own.** It is made on first boot. It is never the owner's key, and no
  nsec of the owner's is on the box.

## Files (`$NV_DATA_DIR/mesh/`)

| File | Written by | Mode | What |
|------|-----------|------|------|
| `nsec` | nv-mesh, first boot | 0600 | The box's mesh key. No API may ever serve it. If it is missing, a new key is made, which changes the npub. If it can't be read or decoded, nv-mesh exits rather than replace it. |
| `npub` | nv-mesh | 0644 | The box's mesh npub. The owner adds it under My Devices on the phone. |
| `devices.json` | havend (box API) | — | The owner's devices: `["npub1…"]`, `[{"npub":"npub1…","name":"…"}]` or `{"devices":[…]}`. It is re-read every 5 s, and a change restarts the engine (as on the Mac), so a removed device drops at once. If the file is unreadable, the last good list is kept. Bad npubs and the box's own npub are skipped. |
| `status.json` | nv-mesh, every 5 s | 0644 | The engine's `NvFipsStatusJSON` plus `npub`, `devices` (count), `error` (plain words, or null) and `updated` (unix s). It is written atomically. havend returns it as `mesh` in `GET /api/box/status`. |

The directory is 0755, so havend can read `npub`/`status.json` and write `devices.json` under its own
uid. Only `nsec` is private.

## Environment

| Var | Default | |
|-----|---------|---|
| `NV_DATA_DIR` | `/data` | |
| `NV_PORT` | `8080` | havend's port. Own devices get it. |
| `NV_MESH_DOOR_PORT` | `NV_PORT+1` (8081) | havend's mesh door, loopback only. It must equal havend's `HAVEN_MESH_PLAIN_PORT`. |
| `NV_MESH_UDP_PORT` | `0` (OS picks) | The mesh UDP port. Set it if the container publishes a port instead of using host networking. |
| `NV_MESH_RELAYS` | the Mac's finder relays | Comma list. Phones find the box on the same relays the Mac uses, so leave it unset. |
| `RUST_LOG` | `info,nostr_relay_pool=warn` | |

## What the other lanes need

- **havend (haven-go/cmd/havend):**
  - Open the mesh door at start: set `HAVEN_MESH_PLAIN_PORT=8081` and serve the door
    (`setMeshServing(true)`). On the Mac, `SetMeshServingC(1)` does this.
  - Mesh traffic reaches 8080 and 8081 from 127.0.0.1. Never treat loopback as the owner: keep owner
    rights on NIP-98/NIP-42.
  - `GET /api/box/devices` reads `devices.json` (and the box npub from `mesh/npub`). Writing it is
    how the owner approves a device.
  - `GET status` gets its `mesh` field from `status.json`.
  - `POST move` needs nv-mesh restarted on the new `NV_DATA_DIR`.
- **Container (linux/ outside mesh/):**
  - Run `nv-mesh` as a second supervised process.
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

1. The box starts with no `devices.json`. `status.json` shows `running:false` and says to add a device.
2. Write the peer's npub to `devices.json`. Within 5 s the engine starts and shares 8080.
3. The peer links directly: NAT traversal uses the box's LAN candidate, then an XK session.
   `curl` through the peer returns the box's 8080.
4. A second peer that is not in `devices.json` gets no answer to its offers and never reaches 8080.
