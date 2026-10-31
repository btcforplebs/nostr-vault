# havend: Nostr Vault on a Linux box

`havend` is the box daemon of the `nostr-vault-linux` container. It runs the
vault engine the Mac app runs, serves everything on one port, and tells
nv-mesh which of the owner's devices to let in. The box has one key, the
mesh's (made by nv-mesh, `linux/mesh/README.md`); havend has none of its own.

## Build

```sh
# from haven-go/
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-X main.version=$V" -o havend ./cmd/havend
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags nolmdb -o haven-engine .
```

Same for `GOARCH=amd64`. Both are static. `-tags nolmdb` gives the engine
Badger only, as libhaven on the Mac has; without it the CLI build needs cgo
for LMDB.

## Contract (container side)

| What | Where |
|---|---|
| Owner | `NV_OWNER` (npub or hex), required, set by the installer. Never claimed by a visitor. |
| Port | `NV_PORT` (8080): relay WebSocket at `/` (and `/private`, `/chat`, `/inbox`, `/feed`), Blossom, web app, `/api/box/` |
| Data | `NV_DATA_DIR` (`/data`): `box/` (state), `vault/` (the engine's working dir), `mesh-devices.json`; `mesh/` is nv-mesh's |
| Engine | `NV_ENGINE_BIN` (`/usr/local/bin/haven-engine`), on `127.0.0.1:NV_ENGINE_PORT` (3355). Run with `HAVEN_BEHIND_PROXY=1`: every client arrives through havend on loopback, so the engine rate-limits the client havend names in `X-Forwarded-For`, and only a request with none (havend's own) or a loopback client keeps the loopback pass |
| Mesh door | `NV_MESH_DOOR_PORT` (`NV_PORT`+1), passed to the engine as `HAVEN_MESH_PLAIN_PORT`: the engine opens the mesh door on `127.0.0.1` at start. nv-mesh sends strangers there; they get only blob reads and owner-signed uploads/events, never the relay port |
| Web app | `NV_WEB_DIR` (built web app; SPA fallback to `index.html`) |
| Box npub | nv-mesh's `/data/mesh/npub`: the one key the owner approves. `havend device` prints it (and fails until nv-mesh's first start). |
| Mesh devices | havend writes `NV_MESH_DEVICES` (`/data/mesh-devices.json`, 0644, atomically, only on change): `[{"npub": …}]`, the owner's other `fipsmesh` entries in their newest 10063, and `[]` while that list doesn't name the box. Refreshed every 30 s and on each devices read; with no list found the file is kept. |
| Mesh status | nv-mesh writes `NV_MESH_STATUS_FILE` (`/data/mesh/status.json`) every 5 s. status returns it as `mesh` with `up` = its `running` while `updated` is under 30 s old, `peers` = the length of its `peers` list, `npub` the box's (no file: `up:false, peers:0`) |
| Update | `NV_UPDATE_HOOK` is run on `POST update`; unset, `/data/box/update-request.json` is written |
| Move | `POST move {path}` only into `NV_MOVE_ROOT` (`/mnt`): mount extra disks there |

## Box API

Owner-only, NIP-98 (`Authorization: Nostr <base64 kind 27235>`): `u` must
name this host, path and query; `method` must match; at most 60 s old; a body
needs its sha256 in `payload`; each proof works once. Anyone else gets 401
(no or bad proof) or 403 (valid proof, not the owner).

- `GET /api/box/status`: `version, uptime, mem {used,total}, disk {used,total}, mesh {up,npub,peers}`, plus `engine, owner, device, move`
- `GET /api/box/storage`: `path, used, free, total` (bytes), plus the vault's breakdown
- `GET /api/box/devices`: `box {npub,name,approved}`, `devices [{npub,name,role,approved}]` (no lastSeen: the 10063 has none)
- `POST /api/box/update`: 202 `{started, from, queued, via}`
- `POST /api/box/move {"path": "/mnt/usb/vault"}`: 202 `{ok, path, message}`, progress in status `move`

Shapes match `web-vault/src/box/api.js`. NIP-42: without `NV_RELAY_URL` the engine accepts AUTH for whatever address the client used (LAN IP, hostname, mesh).

## Approval (My Devices)

The owner adds the box's npub on the phone in My Devices as **Home vault**.
The phone then republishes the owner's kind 10063 with `fipsmesh://<box npub>/`
in it. The box reads the owner's newest 10063 (its own vault first, then
`NV_DIRECTORY_RELAYS`): listed = approved, dropped = revoked. The same list
fills `mesh-devices.json`, so an approved box lets the owner's listed devices
in over the mesh, and a device or box dropped from the list is shut out.

## Test

```sh
go test ./internal/box/
go test -tags havend_e2e -count=1 -v ./cmd/havend/   # builds both, runs with a throwaway key, no outside relays
```
