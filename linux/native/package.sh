#!/bin/sh
# Assemble the one nostr-vault .deb, and from the same files the .rpm and Arch package (build.sh runs this):
#   package.sh <arm64|amd64> <version> <bin dir: havend haven-engine nv-mesh> <web dir> <out dir>
# One package for every machine: the vault and its mesh (system services), plus the desktop window and tray. The
# window's GTK/WebKit libraries are Recommends, so a Pi with no screen (or apt --no-install-recommends) leaves them
# out and the desktop files just sit unused.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
arch=$1 version=$2 bin=$3 web=$4 out=$5
pkg=$(mktemp -d); trap 'rm -rf "$pkg"' EXIT
f() { install -D -m "$1" "$2" "$pkg/$3"; } # f <mode> <from> <to>

# The vault and the mesh.
for p in havend haven-engine nv-mesh; do f 755 "$bin/$p" "usr/lib/nostr-vault/$p"; done
f 755 "$here/lib/prepare" usr/lib/nostr-vault/prepare
f 755 "$here/bin/nostr-vault-setup" usr/bin/nostr-vault-setup
for u in nostr-vault-prepare.service nostr-vault.service nostr-vault-mesh.service; do
  f 644 "$here/systemd/$u" "lib/systemd/system/$u"
done
install -d -m 755 "$pkg/usr/share/nostr-vault"; cp -R "$web" "$pkg/usr/share/nostr-vault/web"
find "$pkg/usr/share/nostr-vault/web" -type d -exec chmod 755 {} +; find "$pkg/usr/share/nostr-vault/web" -type f -exec chmod 644 {} +

# The desktop window and tray (used only where there is a desktop).
f 755 "$here/desktop/nostr-vault-desktop" usr/bin/nostr-vault-desktop
f 644 "$here/desktop/setup.html" usr/share/nostr-vault/desktop/setup.html
f 644 "$here/desktop/app.nostrvault.Desktop.desktop" usr/share/applications/app.nostrvault.Desktop.desktop
f 644 "$here/desktop/nostr-vault-tray.desktop" etc/xdg/autostart/nostr-vault-tray.desktop
f 644 "$here/desktop/app.nostrvault.setup.policy" usr/share/polkit-1/actions/app.nostrvault.setup.policy
f 644 "$here/desktop/nostr-vault-tray.svg" usr/share/icons/hicolor/scalable/apps/nostr-vault-tray.svg
icons=$root/HavenApp/Resources/Assets.xcassets/AppIcon.appiconset
for s in 32 128 256 512; do f 644 "$icons/icon_${s}x${s}.png" "usr/share/icons/hicolor/${s}x${s}/apps/nostr-vault.png"; done

f 644 "$here/README.md" usr/share/doc/nostr-vault/README.md

# The newest glibc symbol any of the three programs asks for: measured from the binaries, not assumed.
# readelf, not objdump: it reads either arch's ELF on any build machine.
glibc=$(for p in havend haven-engine nv-mesh; do readelf -W --dyn-syms "$bin/$p" 2>/dev/null; done \
  | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -u -t. -k1,1n -k2,2n | tail -1)
[ -n "$glibc" ] || { echo "package: couldn't read nv-mesh's glibc needs (readelf)" >&2; exit 1; }

# The same tree as a Fedora .rpm and/or an Arch package too, when NV_PKG_FORMATS lists rpm / archlinux (the .deb is
# always built).
for fmt in ${NV_PKG_FORMATS:-deb}; do
  case "$fmt" in deb) ;; rpm|archlinux) "$here/nfpm.sh" "$fmt" "$arch" "$version" "$pkg" "$glibc" "$out" ;;
    *) echo "package: unknown format $fmt" >&2; exit 1 ;; esac
done

for s in postinst prerm postrm; do f 755 "$here/debian/$s" "DEBIAN/$s"; done
printf '/etc/xdg/autostart/nostr-vault-tray.desktop\n' >"$pkg/DEBIAN/conffiles"

cat >"$pkg/DEBIAN/control" <<CTL
Package: nostr-vault
Version: $version
Architecture: $arch
Maintainer: Nostr Vault <nostr-vault@users.noreply.github.com>
Homepage: https://github.com/btcforplebs/nostr-vault
Section: net
Priority: optional
Depends: libc6 (>= $glibc), libgcc-s1, libnftnl11, libmnl0, libdbus-1-3, systemd, curl, ca-certificates, passwd
Recommends: python3, python3-gi, gir1.2-gtk-3.0, gir1.2-webkit2-4.1 | gir1.2-webkit2-4.0, pkexec | policykit-1, gir1.2-ayatanaappindicator3-0.1 | gir1.2-appindicator3-0.1
Installed-Size: $(du -sk "$pkg" | cut -f1)
Description: your own Nostr vault on this machine
 The vault (relay, Blossom media and the web app) and its FIPS mesh, run as
 system services that start on boot. Phones and computers on the network open
 it at http://<this machine>:8080/; your own devices also reach it over the
 mesh. On a desktop it adds a window and a tray icon. The machine never holds
 your secret key: the mesh has its own key, kept from the vault.
CTL
mkdir -p "$out"
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$out/nostr-vault_${version}_${arch}.deb" >/dev/null
echo "package: $out/nostr-vault_${version}_${arch}.deb (glibc >= $glibc)"
