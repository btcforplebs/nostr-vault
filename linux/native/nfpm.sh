#!/bin/sh
# Turn the file tree package.sh assembled for the .deb into the same package for Fedora (.rpm) and Arch Linux
# (.pkg.tar.zst), with nfpm (https://nfpm.goreleaser.com). package.sh runs this when NV_PKG_FORMATS asks for them:
#   nfpm.sh <rpm|archlinux> <arm64|amd64> <version> <tree> <glibc floor> <out dir>
# The tree is the .deb's, before DEBIAN/ is added. The only change to it: the systemd units move from /lib to
# /usr/lib, because Fedora and Arch have /lib as a symlink that their own filesystem package owns. The maintainer
# scripts are linux/native/debian's, given the argument Debian would pass (rpm and pacman pass other things).
# Needs nfpm and python3.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
fmt=$1 arch=$2 version=$3 tree=$4 glibc=$5 out=$6
command -v nfpm >/dev/null || { echo "nfpm.sh: nfpm is not installed" >&2; exit 1; }
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT

cp -a "$tree" "$w/root"
mkdir -p "$w/root/usr/lib"; mv "$w/root/lib/systemd" "$w/root/usr/lib/systemd"; rmdir "$w/root/lib"
[ -z "$(find "$w/root" -type l)" ] || { echo "nfpm.sh: the tree has symlinks; list them in nfpm.sh" >&2; exit 1; }

# Maintainer scripts: debian's, with "$1" set to what dpkg would have said. rpm runs %preun/%postun on an upgrade
# too ($1 = 1): only an erase ($1 = 0) is a remove. pacman runs pre_remove/post_remove only on a remove. Neither has
# a purge, so a remove keeps the settings, as apt remove does.
body() { sed 1d "$here/debian/$1"; }
{ echo '#!/bin/sh'; echo 'set -- configure'; body postinst; } >"$w/postinst"
for s in prerm postrm; do
  { echo '#!/bin/sh'; echo 'set -- remove'; body $s; } >"$w/$s.arch"
  { echo '#!/bin/sh'; echo '[ "$1" = 0 ] || exit 0'; echo 'set -- remove'; body $s; } >"$w/$s.rpm"
done

python3 -I - "$fmt" "$arch" "$version" "$w" "$glibc" >"$w/nfpm.yaml" <<'PY'
import json, os, sys
fmt, arch, version, w, glibc = sys.argv[1:]
root = os.path.join(w, "root")
contents = []
for d, dirs, files in os.walk(root):
    rel = "/" + os.path.relpath(d, root)
    # Own only our own folders, never /usr, /etc and the rest.
    if rel.startswith(("/usr/lib/nostr-vault", "/usr/share/nostr-vault", "/usr/share/doc/nostr-vault")):
        contents.append({"dst": rel, "type": "dir", "file_info": {"mode": 0o755}})
    for f in sorted(files):
        dst = os.path.normpath(os.path.join(rel, f))
        e = {"src": os.path.join(d, f), "dst": dst}
        if dst == "/etc/xdg/autostart/nostr-vault-tray.desktop":
            e["type"] = "config|noreplace"
        contents.append(e)
# The .deb's Depends and Recommends (package.sh), by each distro's names.
deps = {
    "rpm": (["glibc >= " + glibc, "libgcc", "libnftnl", "libmnl", "dbus-libs", "systemd", "curl", "ca-certificates",
             "shadow-utils"],
            ["python3", "python3-gobject", "gtk3", "webkit2gtk4.1", "polkit", "libayatana-appindicator-gtk3"]),
    # pacman never installs optional deps (an .rpm's and a .deb's Recommends are installed by default), so on Arch the
    # window's packages are real depends: with them optional, a plain Arch install got a window that couldn't start.
    "archlinux": (["glibc>=" + glibc, "gcc-libs", "libnftnl", "libmnl", "dbus", "systemd", "curl", "ca-certificates",
                   "shadow", "python", "python-gobject", "gtk3", "webkit2gtk-4.1", "polkit", "libayatana-appindicator"],
                  []),
}[fmt]
ext = {"rpm": "rpm", "archlinux": "arch"}[fmt]
cfg = {
    "name": "nostr-vault", "arch": arch, "platform": "linux",
    "version": version, "version_schema": "none", "release": "1",
    "maintainer": "Nostr Vault <nostr-vault@users.noreply.github.com>",
    "homepage": "https://github.com/btcforplebs/nostr-vault", "license": "MIT",
    "description": "Your own Nostr vault on this machine: the vault (relay, Blossom media and the web app) and its "
                   "FIPS mesh, run as system services that start on boot. On a desktop it adds a window and a tray icon.",
    "depends": deps[0], "recommends": deps[1],
    "contents": contents,
    "scripts": {"postinstall": f"{w}/postinst", "preremove": f"{w}/prerm.{ext}", "postremove": f"{w}/postrm.{ext}"},
    "archlinux": {"packager": "Nostr Vault <nostr-vault@users.noreply.github.com>",
                  "scripts": {"postupgrade": f"{w}/postinst"}},
    "rpm": {"group": "Applications/Internet", "compression": "zstd"},
}
json.dump(cfg, sys.stdout, indent=1)  # JSON is YAML
PY

# Named as each distro names its packages.
case "$fmt.$arch" in
  rpm.amd64) name=nostr-vault-$version-1.x86_64.rpm ;; rpm.arm64) name=nostr-vault-$version-1.aarch64.rpm ;;
  archlinux.amd64) name=nostr-vault-$version-1-x86_64.pkg.tar.zst ;; archlinux.arm64) name=nostr-vault-$version-1-aarch64.pkg.tar.zst ;;
  *) echo "nfpm.sh: no $fmt for $arch" >&2; exit 1 ;;
esac
mkdir -p "$out"
nfpm package -f "$w/nfpm.yaml" -p "$fmt" -t "$out/$name" >/dev/null
echo "package: $out/$name"
