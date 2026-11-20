# Nostr Vault for Linux

Your vault on a Linux machine: a Raspberry Pi 4/5, a mini PC, a home server or a desktop, arm64 or x86-64.
It runs natively, like the Mac app: system services that start on boot and, on a desktop, a window and a tray icon
(`native/README.md`). You reach it on your local network (and over the mesh). Nothing opens a
port on your router, and the box never holds your secret key.

## Install

Download the package for your system and machine from the
[releases](https://github.com/btcforplebs/nostr-vault/releases) (the Linux beta is a pre-release), check it against
the release's `SHA256SUMS` (`sha256sum -c --ignore-missing SHA256SUMS`), then install it and set the owner:

```sh
sudo apt install ./nostr-vault_<version>_arm64.deb            # Debian, Ubuntu, Raspberry Pi OS (or _amd64)
sudo dnf install ./nostr-vault-<version>-1.x86_64.rpm         # Fedora (or .aarch64)
sudo pacman -U ./nostr-vault-<version>-1-x86_64.pkg.tar.zst   # Arch (or -aarch64)
apk add --allow-untrusted ./nostr-vault-<version>-r0.x86_64.apk   # Alpine, as root (packaging/alpine)
sudo nostr-vault-setup --owner npub1… --data /mnt/ssd/nostr-vault
```

`nostr-vault-setup` takes your **npub** (only that account can manage the vault; nobody can claim it by visiting
first), `--data` for where the vault lives (a USB SSD lasts much longer than an SD card) and `--port` (8080). It
starts the vault and prints its address, e.g. `http://192.168.1.20:8080/`. On a machine with no screen, add
`--no-install-recommends` to apt so it skips the window's libraries. The Flatpak (`flatpak/README.md`) is for
desktops and has no mesh.

On a desktop you can also skip the terminal: install the package and open **Nostr Vault** from your apps; it
asks the same two questions.

Open that address on a phone or computer on the same network, sign in with your Nostr account, and approve the box
in **My Devices** (as with the Mac app). The box makes its own device key on first start; it never sees your nsec.

To update, install the newer package the same way: your vault's data, owner and port stay. A different `--data`
folder starts an empty vault there; to move a vault, use **Storage › Move vault** in the app.

## Day to day (native)

| | |
|---|---|
| Logs | `journalctl -fu nostr-vault -u nostr-vault-mesh` |
| Stop / start | `sudo systemctl stop nostr-vault` / `start` (the mesh goes with it) |
| Settings | `sudo nostr-vault-setup --show`; change them with `sudo nostr-vault-setup --owner … --data … --port …` |
| Update | install the newer package (data, owner and port stay) |

## The Docker box (not for users)

`Dockerfile`, `compose.yml` and `supervise.sh` build and run the same programs as one container,
`nostr-vault-linux`. It is Logen's box for the web app only; nobody else runs it, and users install a package. The
container gets at most 1.5 GB of memory and low CPU priority, restarts by itself (`unless-stopped`), and shares the
machine's network: the vault listens on `NV_PORT` (8080), and on loopback only the engine (3355) and the mesh door
(8081).

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

CI (`.github/workflows/linux-image.yml`) builds the image for amd64 and arm64, each on its own runner, and starts it
to check havend answers. On each published Linux release it pushes both as one index,
`ghcr.io/btcforplebs/nostr-vault-linux:<version>` (the tag without the `v`, never `latest`), and writes the index
digest into the release notes. The Start9 and Umbrel packages pin that digest. Pull requests that touch the image
only build and start it.
