#!/bin/sh
# Build Nostr Vault for Linux, native: the nostr-vault .deb, for each arch asked for (default: this machine's).
#   linux/native/build.sh [arm64] [amd64]          from the repo root or anywhere
# Out: linux/native/out/nostr-vault_<version>_<arch>.deb (and the .rpm and Arch package with NV_PKG_FORMATS) and
# nostr-vault-linux.json (the version and each package's sha256, to check a download against).
#
# Build on Debian 12 (bookworm), arm64 or amd64: its glibc (2.36) is the oldest the packages then need, so they run
# on Raspberry Pi OS 12, Debian 12+ and Ubuntu 22.04+ (measured: glibc 2.34; package.sh reads the floor from the
# binaries and writes it into Depends,
# so apt refuses a system that is too old rather than nv-mesh failing at start). Needs: Go, Node 24,
# Rust 1.94.1 (rustup) and, as linux/mesh/Dockerfile: clang libclang-dev libnftnl-dev libmnl-dev libdbus-1-dev
# pkg-config dpkg-dev. For the other arch's nv-mesh: gcc-x86-64-linux-gnu (or gcc-aarch64-linux-gnu) and the three
# -dev packages for that arch (dpkg --add-architecture), plus `rustup target add`.
# The same programs as the Docker image (linux/Dockerfile), built the same way; keep the two in step.
#
# NV_DEB_VERSION overrides the version (default: the app's MARKETING_VERSION + "+" + the commit count).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$here/out
work=$here/.build
die() { echo "build: $*" >&2; exit 1; }

host=$(dpkg --print-architecture 2>/dev/null) || die "build on Debian or Ubuntu (dpkg is needed)"
archs=${*:-$host}
for a in $archs; do case "$a" in arm64|amd64) ;; *) die "arch must be arm64 or amd64, not $a" ;; esac; done

commit=${NV_COMMIT:-$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}
if [ -z "${NV_DEB_VERSION:-}" ]; then
  marketing=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' "$root/HavenApp/project.yml" | head -1)
  count=$(git -C "$root" rev-list --count HEAD 2>/dev/null) || die "no git here: set NV_DEB_VERSION"
  NV_DEB_VERSION="${marketing:?no MARKETING_VERSION in HavenApp/project.yml}+$count"
fi
version=$NV_DEB_VERSION
printf '%s' "$version" | grep -Eq '^[0-9][0-9A-Za-z.+~]*$' || die "bad version $version"
echo "build: Nostr Vault $version ($commit) for $archs"
rm -rf "$work"; mkdir -p "$work" "$out"

# 1. The web app, once (the same for every arch): the box build, as the image's.
# NV_SKIP_WEB=1 reuses the last web build (linux/native/.web), for quick rebuilds of the rest.
if [ "${NV_SKIP_WEB:-0}" != 1 ] || [ ! -s "$here/.web/index.html" ]; then
  (cd "$root" && web-relay/tools/build-haven-wasm.sh)
  (cd "$root/web-relay" && npm ci --ignore-scripts --no-audit --no-fund)
  (cd "$root/web-vault" && npm ci --ignore-scripts --no-audit --no-fund && NV_BOX=1 NV_COMMIT=$commit npm run build)
  test -s "$root/web-vault/dist/index.html" || die "the web app didn't build"
  rm -rf "$here/.web"; cp -R "$root/web-vault/dist" "$here/.web"
fi

for arch in $archs; do
  bin=$work/$arch; mkdir -p "$bin"
  # 2. havend and the engine: pure Go, -tags nolmdb for the engine (Badger only), as the image.
  (cd "$root/haven-go" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "-s -w -X 'main.version=$version ($commit)'" -o "$bin/havend" ./cmd/havend \
    && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "-s -w" -tags nolmdb -o "$bin/haven-engine" .)
  # 3. nv-mesh (Rust; links nftables and D-Bus, see linux/mesh/Dockerfile).
  tdir=${CARGO_TARGET_DIR:-$root/linux/mesh/target}
  if [ "$arch" = "$host" ]; then
    (cd "$root/linux/mesh" && cargo build --release --locked)
    cp "$tdir/release/nv-mesh" "$bin/nv-mesh"
  else
    case "$arch" in amd64) t=x86_64-unknown-linux-gnu gnu=x86_64-linux-gnu ;; arm64) t=aarch64-unknown-linux-gnu gnu=aarch64-linux-gnu ;; esac
    tu=$(echo "$t" | tr 'a-z-' 'A-Z_')
    (cd "$root/linux/mesh" && env "CARGO_TARGET_${tu}_LINKER=$gnu-gcc" "CC_$(echo "$t" | tr - _)=$gnu-gcc" \
      PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_LIBDIR="/usr/lib/$gnu/pkgconfig:/usr/share/pkgconfig" \
      BINDGEN_EXTRA_CLANG_ARGS="--target=$gnu -I/usr/include/$gnu" \
      cargo build --release --locked --target "$t")
    cp "$tdir/$t/release/nv-mesh" "$bin/nv-mesh"
  fi
  "$here/package.sh" "$arch" "$version" "$bin" "$here/.web" "$out"
done

# 4. The manifest: the version and each .deb's sha256.
(cd "$out" && python3 -I - "$version" <<'PY'
import hashlib, json, os, sys
v = sys.argv[1]
# Every package of this version: the .deb, and the .rpm and Arch package when NV_PKG_FORMATS made them.
mine = lambda f: (f.endswith(".deb") and f"_{v}_" in f) or ((f.endswith(".rpm") or f.endswith(".pkg.tar.zst")) and f"-{v}-1" in f)
files = {f: hashlib.sha256(open(f, "rb").read()).hexdigest() for f in sorted(os.listdir(".")) if mine(f)}
json.dump({"version": v, "files": files}, open("nostr-vault-linux.json", "w"), indent=1)
print("\n".join(f"{h}  {f}" for f, h in files.items()))
PY
)
rm -rf "$work"
echo "build: done, in $out"
