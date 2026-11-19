#!/bin/sh
# Lays out what the Flatpak build reads, so flatpak-builder can build with no network (see README.md):
#   .build/src/                 the parts of this repo the app is built from (git archive of HEAD), plus nv-version.env
#   .build/go-sources.json      every Go module the builds need (linux + js/wasm), as proxy.golang.org files with sha256
#   .build/npm-*-sources.json   web-relay's and web-vault's npm packages (flatpak-node-generator, from package-lock.json)
#   shared-modules/             flathub/shared-modules at a pinned commit (the Ayatana tray library)
# Needs: git, go (>= haven-go/go.mod's), python3, flatpak-node-generator (pipx, README.md). Run from anywhere.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
b=$here/.build
SHARED_MODULES=c91a81101cf9bcf9fc8132e8c3ebed741ad8bae6
rm -rf "$b"; mkdir -p "$b/src"

# 1. The source tree: committed files only, so a dirty checkout can't leak into a build.
git -C "$root" archive --format=tar HEAD haven-go web-relay web-vault linux/native/desktop linux/flatpak LICENSE \
  | tar -x -C "$b/src"
mkdir -p "$b/src/icons"
for s in 128 256 512; do
  git -C "$root" show "HEAD:HavenApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}.png" > "$b/src/icons/icon_${s}x${s}.png"
done
commit=$(git -C "$root" rev-parse --short=12 HEAD)
marketing=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' "$root/HavenApp/project.yml" | head -1)
version=${NV_FLATPAK_VERSION:-${marketing:?no MARKETING_VERSION}+$(git -C "$root" rev-list --count HEAD)}
printf 'NV_VERSION=%s\nNV_COMMIT=%s\n' "$version" "$commit" > "$b/src/nv-version.env"
echo "gen-sources: Nostr Vault $version ($commit)"

# 2. Go: fill an empty module cache with what the three builds need, then list each file the proxy served.
gm=$(mktemp -d)
(
  cd "$b/src/haven-go"
  export GOMODCACHE="$gm" GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org
  go mod download
  for t in linux/amd64 linux/arm64; do
    GOOS=linux GOARCH=${t#*/} go list -deps ./cmd/havend >/dev/null
    GOOS=linux GOARCH=${t#*/} go list -deps -tags nolmdb . >/dev/null
  done
  GOOS=js GOARCH=wasm go list -deps . >/dev/null
)
python3 -I - "$gm/cache/download" "$b/go-sources.json" <<'PY'
import hashlib, json, os, sys
top, out = sys.argv[1], sys.argv[2]
srcs = []
for d, _dirs, files in os.walk(top):
    rel = os.path.relpath(d, top)
    if rel.split(os.sep)[0] == "sumdb":
        continue
    for f in sorted(files):
        if not f.endswith((".info", ".mod", ".zip")):
            continue  # .lock, .partial, .ziphash and list are the cache's own, not the proxy's
        h = hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()
        srcs.append({"type": "file", "url": f"https://proxy.golang.org/{rel}/{f}", "sha256": h,
                     "dest": f"gomod/{rel}", "dest-filename": f})
srcs.sort(key=lambda s: s["url"])
json.dump(srcs, open(out, "w"), indent=1)
print(f"gen-sources: {len(srcs)} Go module files")
PY
chmod -R u+w "$gm" && rm -rf "$gm"

# 3. npm: both lockfiles. --no-devel would drop vite, which the build needs.
flatpak-node-generator npm "$b/src/web-relay/package-lock.json" -o "$b/npm-relay-sources.json"
flatpak-node-generator npm "$b/src/web-vault/package-lock.json" -o "$b/npm-vault-sources.json"

# 4. The tray library's recipe.
if [ "$(git -C "$here/shared-modules" rev-parse HEAD 2>/dev/null)" != "$SHARED_MODULES" ]; then
  rm -rf "$here/shared-modules"
  git clone -q https://github.com/flathub/shared-modules.git "$here/shared-modules"
  git -C "$here/shared-modules" checkout -q "$SHARED_MODULES"
fi
echo "gen-sources: done, in $b"
