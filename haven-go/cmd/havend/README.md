# havend: Nostr Vault on a Linux box

`havend` is the box daemon of the `nostr-vault-linux` container. It runs the
vault engine the Mac app runs, serves everything on one port, and keeps the
box's own device key.

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
| Data | `NV_DATA_DIR` (`/data`): `box/` (device key, state), `vault/` (the engine's working dir) |
| Engine | `NV_ENGINE_BIN` (`/usr/local/bin/haven-engine`), on `127.0.0.1:NV_ENGINE_PORT` (3355) |
| Web app | `NV_WEB_DIR` (built web app; SPA fallback to `index.html`) |
| Device key | `/data/box/device.key`, hex, 0600. `havend device` prints its npub. |
| Mesh status | the mesh writes a JSON object to `NV_MESH_STATUS_FILE` (`/data/mesh/status.json`) with at least `{up, npub, peers}`; status passes it through as `mesh` (no file: `{up:false}`; `npub` defaults to the box's) |
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
`NV_DIRECTORY_RELAYS`): listed = approved, dropped = revoked.

## Test

```sh
go test ./internal/box/
go test -tags havend_e2e -count=1 -v ./cmd/havend/   # builds both, runs with a throwaway key, no outside relays
```
