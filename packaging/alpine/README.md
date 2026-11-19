# Nostr Vault for Alpine Linux

The same vault as the `.deb` (`linux/native/README.md`): havend + haven-engine, nv-mesh and the web app's box build,
built against musl and run by OpenRC (Alpine has no systemd). One `nostr-vault` apk per arch (x86_64, aarch64). No
desktop window or tray: the vault's page is on `http://<machine>:8080/` for any phone or computer on the network.

```sh
apk add ./nostr-vault-<version>-r0.<arch>.apk        # the signing key in /etc/apk/keys, or --allow-untrusted
nostr-vault-setup --owner npub1…                     # starts it now and on every boot
```

## What's in it

| | |
|---|---|
| The vault | `/usr/lib/nostr-vault/`: havend, haven-engine (static Go), nv-mesh (Rust, musl, links Alpine's libnftnl, libmnl, libdbus), prepare (the `.deb`'s, as is). `/usr/share/nostr-vault/web`: the web app. `/usr/bin/nostr-vault-setup` (the OpenRC twin of the `.deb`'s: same options and checks). |
| Services | `/etc/init.d/nostr-vault` (havend as `nvvault`, port `NV_PORT`; its start runs `prepare` first) and `/etc/init.d/nostr-vault-mesh` (nv-mesh as `nvmesh`; it needs `nostr-vault`, so stopping the vault stops the mesh). Both under supervise-daemon (a crash restarts in 2 s), nice 10, no new privileges, no capabilities. |
| Users | `nvvault` (uid 10002) and `nvmesh` (10001), the container's uids when they are free, so a Docker box's data dir works as it is. |

Settings: `/etc/nostr-vault/vault.env` (`NV_OWNER`, `NV_DATA_DIR`, `NV_PORT`, …; read as shell `KEY=value` lines) and
`/etc/nostr-vault/secrets.env` (0600, the vault's only). Logs: `/var/log/nostr-vault/vault.log` and `mesh.log`.
Stop or start: `rc-service nostr-vault stop` (the mesh stops with it). Removing the apk stops both and takes them
off the default runlevel; the data dir and `/etc/nostr-vault` stay.

Not the same as the `.deb`: OpenRC has no `ProtectSystem` sandbox or memory caps, so the services run as their own
users with no capabilities, but without the systemd units' read-only system around them.

## Build and test

CI (`.github/workflows/linux-alpine.yml`) builds the web app once, then runs `build.sh` in `alpine:3.22` on each
arch's own runner and installs the apk in an Alpine container that boots OpenRC (`test/Dockerfile`), on 3.22 and
the latest: install (signature checked), setup, the same checks as the `.deb`'s test, a container restart (a reboot)
and the vault back by itself, a crash restart, remove and add again. By hand, from the repo root, with the web app's
box build in `web-vault/dist`:

```sh
docker run --rm -v "$PWD:/src" -w /src alpine:3.22 packaging/alpine/build.sh /src/web-vault/dist /src/out-apk
```

The apk is signed with a throwaway key made in the build: nothing here is published. A release needs its own
signing key (its `.rsa.pub` for `/etc/apk/keys`), and `linux/install.sh` doesn't know about Alpine yet.
