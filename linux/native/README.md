# Nostr Vault for Linux, native

The Mac app, for Linux: the vault runs on the machine itself (no Docker), starts on boot, and on a desktop has a
window and a tray icon. The same programs as the `nostr-vault-linux` container (havend + haven-engine, nv-mesh,
the web app's box build), run by systemd instead of `supervise.sh`. Raspberry Pi OS, Debian 12+, Ubuntu 22.04+;
arm64 and x86-64.

Install the package from a release (`linux/README.md`):

```sh
sudo apt install ./nostr-vault_<version>_arm64.deb    # add --no-install-recommends on a machine with no screen
sudo nostr-vault-setup --owner npub1…              # or open Nostr Vault from the apps: it asks the same
```

## The Mac app, on Linux

| Mac | Linux |
|---|---|
| Setup (whose vault, where) | the window's first page, or `nostr-vault-setup` (pkexec from the window) |
| The relay in the app (libhaven) | `nostr-vault.service`: havend, which runs haven-engine on 127.0.0.1:3355 |
| The mesh engine (`macEngineOptions`) | `nostr-vault-mesh.service`: nv-mesh, the same options (linux/mesh/README.md) |
| The window | `nostr-vault-desktop`: the vault's web app in a WebKitGTK window: feed, vault, My Devices (`#/box`), settings |
| Menu bar item | tray icon: status, Open, New Note, Feed / Vault / My Devices / Settings, Copy box npub |
| Closing the window | the window and its web view end (WebKit's web and network processes with them); the tray starts over on its own, small, and Open makes a new window, still signed in |
| A window that draws nothing | it checks it draws (its page answers, WebKit put pixels in it); if not, it starts over with DMA-BUF switched, then GPU compositing off, keeps what worked in `~/.config/nostr-vault-desktop/renderer.json`, and last shows a GTK page that opens the vault in the browser (`nv_paint.py`). DMA-BUF starts off only on the NVIDIA driver. An update restarts an open window on the new version (postinst sends it SIGUSR1) |
| Launch at login | the vault on boot (systemd); the tray at login (`/etc/xdg/autostart`) |
| Update | `apt install` the newer `.deb`: data, owner and port stay |

A machine with no screen is the same minus the window: the vault's page is on `http://<machine>:8080/` for
any phone or computer on the network, as with the container.

## The package

One `nostr-vault` package per arch (arm64, amd64), for every machine:

| | |
|---|---|
| The vault | `/usr/lib/nostr-vault/`: havend, haven-engine, nv-mesh, prepare. `/usr/share/nostr-vault/web`: the web app. `/usr/bin/nostr-vault-setup`. The systemd units. Users `nvvault` (uid 10002) and `nvmesh` (10001): the container's uids, so a Docker box's data dir works as it is. |
| The window and tray | `/usr/bin/nostr-vault-desktop` (Python, GTK 3, WebKitGTK 4.1, AyatanaAppIndicator), its setup page, the menu entry, the tray's autostart and the pkexec policy for `nostr-vault-setup`. Their libraries are `Recommends`: a machine with no screen installs with `--no-install-recommends` and these files sit unused. |

`Depends` names the newest glibc the binaries ask for, read from them by `package.sh`, so apt refuses a system that
is too old instead of nv-mesh failing at start.

## Services

| Unit | Runs | As |
|---|---|---|
| `nostr-vault-prepare.service` | `prepare`: the data dir 0711 (the vault's), `mesh/` 0755 (the mesh's), as `supervise.sh` does | root, once |
| `nostr-vault.service` | havend on `NV_PORT` (all addresses), the engine on 127.0.0.1:3355, the mesh door on 127.0.0.1:`NV_PORT+1` | `nvvault` |
| `nostr-vault-mesh.service` | nv-mesh; its key `mesh/key/` is readable by it alone | `nvmesh` |

Both programs: no capabilities, no new privileges, a read-only system (`ProtectSystem=strict`) with only their own
folders writable, nice 10, the container's memory caps (1.5 GB vault, 512 MB mesh). `nostr-vault-setup` adds a
drop-in when the data dir isn't `/var/lib/nostr-vault`. Stop or start the vault: `sudo systemctl stop nostr-vault`
(the mesh stops with it). Logs: `journalctl -fu nostr-vault -u nostr-vault-mesh`.

Settings: `/etc/nostr-vault/vault.env` (`NV_OWNER`, `NV_DATA_DIR`, `NV_PORT`, …; no secrets, so 0644: the
window reads the port from it). Anything secret (backup `NV_S3_*`) goes in `/etc/nostr-vault/secrets.env` (0600).

## Pairing and the mesh

As on the Mac and the container: the box makes its own mesh key on first start (never the owner's key; no nsec of
the owner's is on the machine), the owner adds the box's npub on the phone (My Devices › Add a device: scan, or
the tray's **Copy box npub**), and havend lets in the devices the owner's 10063 lists. Strangers reach only the
capped mesh door. Nothing publishes the home IP: only own devices get answers to traversal offers.

## Update

`apt install` a newer `.deb` (or the newer package for dnf, pacman, apk). The app's **Update** button says the same: havend runs no
update itself here (no `NV_UPDATE_HOOK`). An in-app updater needs a release signing key first (the sha256 in the
manifest comes from the same release as the file, so it catches a broken download, not a forged one).

## Build

On Debian 12 (bookworm), from the repo root: `linux/native/build.sh arm64 amd64`. The other arch's nv-mesh is
cross-built (see the script's header for the packages). Out: `linux/native/out/` (one `.deb` per arch and the
manifest). Attach all of `out/` to a GitHub release.
