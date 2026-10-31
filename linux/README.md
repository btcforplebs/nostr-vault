# Nostr Vault for Linux

Your vault on a small always-on Linux machine: a Raspberry Pi 4/5, a mini PC or a home server, arm64 or x86-64.
It runs as one Docker container, `nostr-vault-linux`, and you reach it on your local network (and over the mesh).
Nothing opens a port on your router, and the box never holds your secret key.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/btcforplebs/nostr-vault/master/linux/install.sh | sh
```

The installer:

1. installs Docker if it isn't there (from get.docker.com);
2. asks **Where should your vault live?** and suggests the drive with the most free space. On an SD card it warns
   you first: a vault writes all the time, and a USB SSD lasts much longer;
3. asks for **your npub**. Only that account can manage the vault. Nobody can claim it by visiting first;
4. starts the vault and prints its address, e.g. `http://192.168.1.20:8080/`.

Open that address on a phone or computer on the same network, sign in with your Nostr account, and approve the box
in **My Devices** (as with the Mac app). The box makes its own device key on first start; it never sees your nsec.

Run the installer again to update or to change an answer: your vault's data stays where it is. Choosing a different
place starts an empty vault there (the installer asks first); to move a vault, use **Storage › Move vault** in the app.

Answers can be given ahead, for scripts: `NV_DATA_HOST=/mnt/ssd/nostr-vault NV_OWNER=npub1… NV_YES=1 sh install.sh`.
Also `NV_PORT` (8080), `NV_IMAGE`, `NV_HOME` (`/opt/nostr-vault`).

## Day to day

| | |
|---|---|
| Logs | `sudo docker logs -f nostr-vault-linux` |
| Stop / start | `sudo docker compose --project-directory /opt/nostr-vault down` / `up -d` |
| Settings | `/opt/nostr-vault/.env` (owner, data path, port, image) |
| Update | run the installer again, or **Update** in the app |

The container gets at most 1.5 GB of memory and low CPU priority, restarts by itself (`unless-stopped`), and keeps
3 × 10 MB of logs. It shares the machine's network, so the mesh can offer your devices its real LAN address: the
vault listens on `NV_PORT` (8080), and on loopback only the engine (3355) and the mesh door (8081). The installer
checks those are free.

## Inside the container (for the four lanes)

| | |
|---|---|
| `/app/bin/supervise` | the one supervisor (under tini). Starts as root only to set up `/data`, then runs each program as its own user with no capabilities and no new privileges (setpriv), at nice 10. Starts either again when it exits (1 s, doubling to 30 s; back to 1 s after a minute up), stops both on `docker stop`. Refuses to start without a valid `NV_OWNER`. |
| `/app/bin/havend` (uid 10002 `vault`) | the vault (haven-go/cmd/havend): the relay websocket at `/` (Upgrade), Blossom, the web app and the owner-only box API under `/api/box/` (NIP-98), all on `NV_PORT`. It runs `/usr/local/bin/haven-engine` (pure Go, Badger) on `127.0.0.1:3355`. |
| `/app/bin/nv-mesh` (uid 10001 `nvmesh`) | the mesh (linux/mesh/README.md). Own devices reach `NV_PORT`; strangers only the mesh door (`NV_MESH_DOOR_PORT`, 8081). |
| `/app/web` | the web app (`NV_WEB_DIR`), built with `NV_BOX=1`: served at the box's root, its vault the box itself. |
| `/data` | `NV_DATA_DIR`: the host path the owner chose. Mode 0711, havend's: `box/` (device key, state), `vault/` (the engine's), `mesh-devices.json`. `mesh/` is nv-mesh's (0755): `key/` (0700, the mesh key, nv-mesh only), `npub`, `status.json`. |

Environment: `NV_OWNER` (npub or hex, required), `NV_DATA_DIR=/data`, `NV_PORT=8080`, `NV_MESH_DOOR_PORT=8081`
(= `HAVEN_MESH_PLAIN_PORT`), `NV_WEB_DIR=/app/web`, `NV_ENGINE_BIN`, `NV_VERSION` (the build's commit). The health
check passes when anything answers HTTP on `NV_PORT`.

## Build

From the repo root, on any machine with Docker Buildx. The Go programs and the web app build on the machine's own
arch; nv-mesh (Rust) builds per target, so the foreign arch builds under emulation (slow the first time, then cached):

```sh
docker buildx build --platform linux/arm64,linux/amd64 -f linux/Dockerfile -t nostr-vault-linux .
```

`linux/test/check.sh` checks the scripts and the compose file.
