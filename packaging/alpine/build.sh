#!/bin/sh
# Build the nostr-vault apk for this machine's arch, on Alpine (musl). Run as root in a throwaway Alpine container,
# from the repo root (CI: .github/workflows/linux-alpine.yml):
#   docker run --rm -v "$PWD:/src" -w /src alpine:3.22 packaging/alpine/build.sh <web dir> <out dir>
# <web dir> is the web app's box build (the same for every arch; CI makes it once, as linux/native/build.sh step 1).
# Out: <out dir>/nostr-vault-<version>-r0.<arch>.apk, the throwaway CI key's .rsa.pub it is signed with, and
# nostr-vault-alpine.json (version, apk sha256). Nothing is published.
#
# The programs are the .deb's (linux/native/build.sh), built here against musl: havend and haven-engine pure Go
# (static), nv-mesh Rust against musl (dynamic, -crt-static off: proc macros and build scripts need it; at run time
# it needs only musl and libgcc, as scanelf shows below).
# NV_APK_VERSION overrides the version (default: the app's MARKETING_VERSION + "_p" + the commit count).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
web=${1:?usage: build.sh <web dir> <out dir>}; out=${2:?usage: build.sh <web dir> <out dir>}
die() { echo "build: $*" >&2; exit 1; }
[ -f /etc/alpine-release ] || die "run on Alpine (see the header)"
[ -s "$web/index.html" ] || die "no web app in $web"
mkdir -p "$out"; out=$(cd "$out" && pwd); web=$(cd "$web" && pwd)

apk add -q --no-progress build-base clang-dev clang-libclang libnftnl-dev libmnl-dev dbus-dev linux-headers pkgconf \
  rustup go git abuild python3 file
git config --global --add safe.directory "$root"
commit=${NV_COMMIT:-$(git -C "$root" rev-parse --short=12 HEAD)}
if [ -z "${NV_APK_VERSION:-}" ]; then
  marketing=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' "$root/HavenApp/project.yml" | head -1)
  count=$(git -C "$root" rev-list --count HEAD) || die "no git history: set NV_APK_VERSION"
  NV_APK_VERSION="${marketing:?no MARKETING_VERSION in HavenApp/project.yml}_p$count"
fi
version=$NV_APK_VERSION
printf '%s' "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*(_p[0-9]+)?$' || die "bad apk version $version"
echo "build: Nostr Vault $version ($commit) for $(apk --print-arch), Alpine $(cat /etc/alpine-release)"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
bin=$work/aports/nv/nostr-vault/stage; mkdir -p "$bin"

# 1. havend and the engine: pure Go, -tags nolmdb for the engine (Badger only), as the .deb and the image.
# Alpine's go pins GOTOOLCHAIN=local; haven-go/go.mod names the toolchain, so let go fetch it.
export GOTOOLCHAIN=auto GOFLAGS=-buildvcs=false
(cd "$root/haven-go" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X 'main.version=$version ($commit)'" -o "$bin/havend" ./cmd/havend \
  && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -tags nolmdb -o "$bin/haven-engine" .)

# 2. nv-mesh: the pinned Rust (linux/mesh/rust-toolchain.toml), the musl host target, linked dynamically
# (-crt-static off, as Alpine's own Rust does).
rustup-init -y -q --profile minimal --default-toolchain none >/dev/null
. "$HOME/.cargo/env"
rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/linux/mesh/rust-toolchain.toml")" --profile minimal
(cd "$root/linux/mesh" && CARGO_TARGET_DIR=$work/target RUSTFLAGS="-C target-feature=-crt-static" cargo build --release --locked)
cp "$work/target/release/nv-mesh" "$bin/nv-mesh"
cp "$root/linux/native/lib/prepare" "$bin/prepare"
cp -R "$web" "$bin/web"
for p in havend haven-engine nv-mesh; do printf '%s: ' "$p"; file -b "$bin/$p" 2>/dev/null || echo; done
echo "nv-mesh links:"; scanelf -n "$bin/nv-mesh" 2>/dev/null || true

# 3. The apk: abuild with a throwaway key made here (the release's real key waits for Logen; nothing is published).
d=$work/aports/nv/nostr-vault
for f in APKBUILD README.md nostr-vault-setup nostr-vault.initd nostr-vault-mesh.initd \
  nostr-vault.pre-install nostr-vault.post-install nostr-vault.post-upgrade nostr-vault.pre-deinstall; do
  cp "$here/$f" "$d/$f"
done
sed -i "s/^pkgver=.*/pkgver=$version/" "$d/APKBUILD"
export PACKAGER="Nostr Vault CI <nostr-vault@users.noreply.github.com>"
abuild-keygen -a -i -n >/dev/null  # -i: into /etc/apk/keys, so abuild can index its repo
(cd "$d" && abuild -F -d -P "$work/repo")
apk=$(find "$work/repo" -name "nostr-vault-$version-r*.apk" | head -1)
[ -n "$apk" ] || die "abuild made no apk"
arch=$(apk --print-arch)
name="nostr-vault-$version-r0.$arch.apk"
cp "$apk" "$out/$name"
cp "$HOME"/.abuild/*.rsa.pub "$out/"
python3 -I - "$out" "$version" "$name" <<'PY'
import hashlib, json, os, sys
out, v, name = sys.argv[1:]
h = hashlib.sha256(open(os.path.join(out, name), "rb").read()).hexdigest()
json.dump({"version": v, "files": {name: h}}, open(os.path.join(out, "nostr-vault-alpine.json"), "w"), indent=1)
print(f"{h}  {name}")
PY
echo "build: done, $out/$name"
