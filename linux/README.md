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
3 × 10 MB of logs.

## Inside the container (for the four lanes)

| | |
|---|---|
| `/app/bin/supervise` | the one supervisor (under tini): runs `havend` and `nv-mesh` at nice 10, starts either again when it exits (1 s, doubling to 30 s; back to 1 s after a minute up), stops both on `docker stop`. Refuses to start without a valid `NV_OWNER` or a writable `/data`. |
| `/app/bin/havend` | the vault (haven-go/cmd/havend). Listens on `NV_PORT` (8080) and serves everything: the relay websocket at `/` (Upgrade), Blossom like the Mac, the web app, and the owner-only box API under `/api/box/` (NIP-98). |
| `/app/bin/nv-mesh` | the mesh process (linux/mesh/). |
| `/app/web` | the web app (`NV_WEB_DIR`), built with `NV_BOX=1`. Its base is `/vault/`, so havend serves it there and sends a plain `GET /` to `/vault/`. |
| `/data` | `NV_DATA_DIR`: the host path the owner chose, owned by the image's `vault` user (uid 10001), mode 700. |

Environment: `NV_OWNER` (npub or hex, required), `NV_DATA_DIR=/data`, `NV_PORT=8080`, `NV_WEB_DIR=/app/web`,
`NV_VERSION` (the build's commit). The health check passes when anything answers HTTP on `NV_PORT`.

Until havend and the mesh process land, `linux/stubs/` stand in for them (same names and port, nothing kept): the
web app is served, `/api/box/status` says `"stub": true`, and the rest of `/api/box/` and the relay answer 501.

## Build

From the repo root, on any machine with Docker Buildx (both arches build natively except the runtime's `apt-get`):

```sh
docker buildx build --platform linux/arm64,linux/amd64 -f linux/Dockerfile -t nostr-vault-linux .
```

`linux/test/check.sh` checks the scripts and the compose file.
