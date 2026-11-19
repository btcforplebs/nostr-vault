# Nostr Vault Flatpak (Linux desktops)

For Steam Deck (Desktop Mode), Fedora Silverblue, Bazzite and any desktop with Flatpak. The `.deb` (`linux/native`)
stays for Pis and servers that run the vault at boot.

- **What runs:** the window (`linux/native/desktop/nostr-vault-desktop`) runs the vault itself while you're logged in
  (`nv_flatpak.py`): havend as a child process, restarted when it exits. Settings are in
  `~/.var/app/app.nostrvault.Desktop/config/nostr-vault/vault.env`, data in `.../data/nostr-vault`, the log in
  `.../.local/state/nostr-vault/havend.log`. Uninstalling with `--delete-data` deletes the vault.
- **Port:** 8080, or the next free pair up to 8199 when a `.deb` on the same machine holds it. Saved at setup.
- **At login:** the Background portal (asked once). It starts `nostr-vault-desktop --tray`. With no tray (stock
  GNOME), the vault runs as a background app, and opening the app shows the window. Closing the window never stops it.
  Quit is in the tray and on Ctrl+Q.
- **No mesh yet.** The mesh key must stay apart from the vault, and that part is reviewed on its own before it ships.
- **Not on Flathub.** CI makes a `.flatpak` bundle per arch as a run artifact. Nothing is published.

## Build

`flatpak-builder` builds with no network. `gen-sources.sh` lays out every source first: the repo's files at HEAD,
each Go module as a proxy.golang.org file with its sha256, the npm packages from both `package-lock.json` files
(flatpak-node-generator), and flathub/shared-modules at a pinned commit (the Ayatana tray).

```sh
pipx install "git+https://github.com/flatpak/flatpak-builder-tools.git@9d86d336a39b9af38b86f114b6ce5820fe260f91#subdirectory=node"
linux/flatpak/gen-sources.sh
cd linux/flatpak
flatpak-builder --user --install-deps-from=flathub --force-clean --repo=repo --default-branch=stable builddir app.nostrvault.Desktop.yml
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo repo nostr-vault.flatpak app.nostrvault.Desktop stable
flatpak install --user nostr-vault.flatpak
```

CI: `.github/workflows/linux-flatpak.yml` (x86_64 + aarch64, then `test/smoke.py` inside the installed app).
