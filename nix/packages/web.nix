# The vault's web app, the box build (NV_BOX=1) havend serves at its root: the same steps as linux/native/build.sh
# step 1 and linux/Dockerfile's `web` stage. haven.wasm is haven-go built for js/wasm; web-vault imports it and the
# @fips packages from ../web-relay, so both npm trees are installed.
#
# web-relay/tools/build-haven-wasm.sh builds with -mod=mod (it fetches modules), so its two steps are done here
# with havend's vendored modules instead: the same go.mod, the same module set.
{
  lib,
  stdenvNoCC,
  fetchNpmDeps,
  nodejs,
  go,
  havend,
  src,
  version,
  commit ? "unknown",
}:

let
  relayDeps = fetchNpmDeps {
    name = "nostr-vault-web-relay-npm-deps";
    src = "${src}/web-relay";
    hash = "sha256-YvDLT+IuN4hItqE3ma3C6LO+37BlY4iPc33y1DfaE8E=";
  };
  vaultDeps = fetchNpmDeps {
    name = "nostr-vault-web-vault-npm-deps";
    src = "${src}/web-vault";
    hash = "sha256-4sTgoTxDIXo10iEoq0Cmrcsu8psA9O098eP6kyfe0wE=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "nostr-vault-web";
  inherit version src;

  nativeBuildInputs = [
    nodejs
    go
  ];

  env = {
    NV_BOX = "1";
    NV_COMMIT = commit;
    GOTOOLCHAIN = "local";
    GOPROXY = "off";
    GOFLAGS = "-mod=vendor -trimpath";
    npm_config_offline = "true";
    npm_config_audit = "false";
    npm_config_fund = "false";
    npm_config_progress = "false";
  };

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOPATH=$TMPDIR/go

    # 1. haven.wasm and its Go runtime shim (build-haven-wasm.sh).
    cp -r ${havend.goModules} haven-go/vendor
    chmod -R u+w haven-go/vendor
    (cd haven-go && CGO_ENABLED=0 GOOS=js GOARCH=wasm go build -ldflags="-s -w" -o ../web-relay/public/haven.wasm .)
    shim=$(go env GOROOT)/lib/wasm/wasm_exec.js
    [ -f "$shim" ] || shim=$(go env GOROOT)/misc/wasm/wasm_exec.js
    cp "$shim" web-relay/src/haven/wasm_exec.js
    test -s web-relay/public/haven.wasm

    # 2. Both npm trees, offline from the prefetched caches.
    install_npm() { # install_npm <dir> <deps>
      cache=$TMPDIR/npm-cache-$1
      cp -r "$2" "$cache"; chmod -R u+w "$cache"
      (cd "$1" && npm_config_cache="$cache" npm ci --ignore-scripts)
    }
    install_npm web-relay ${relayDeps}
    install_npm web-vault ${vaultDeps}
    patchShebangs web-relay/node_modules web-vault/node_modules

    # 3. The box build.
    (cd web-vault && npm run build)
    test -s web-vault/dist/index.html
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/nostr-vault
    cp -R web-vault/dist $out/share/nostr-vault/web
    runHook postInstall
  '';

  meta = {
    description = "Nostr Vault web app, box build (served by havend)";
    homepage = "https://github.com/btcforplebs/nostr-vault";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
