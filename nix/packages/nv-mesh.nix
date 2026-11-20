# nv-mesh: the FIPS mesh engine the Mac app runs (fips-v2-android, lib nvfips), as its own process next to havend.
# Same sources as linux/mesh/Dockerfile: linux/mesh, fips-v2-android, web-relay-vault and fips-v2/src/stack.rs.
# fips links nftables (rustables, through bindgen) and BlueZ over D-Bus (bluer).
{
  lib,
  rustPlatform,
  pkg-config,
  libnftnl,
  libmnl,
  dbus,
  src,
  version,
}:

rustPlatform.buildRustPackage {
  pname = "nv-mesh";
  inherit version src;

  cargoRoot = "linux/mesh";
  buildAndTestSubdir = "linux/mesh";
  cargoLock = {
    lockFile = ../../linux/mesh/Cargo.lock;
    outputHashes = {
      # btcforplebs/fips branch nv/v0.5.3 at eb642842: the same rev fips-v2-android and web-relay-vault pin.
      "fips-mesh-0.5.3" = "sha256-l4MZZuC0fcJNFlA3CjIFwSdRSeoCeOcFCYonXnSo8oA=";
    };
  };

  nativeBuildInputs = [
    pkg-config
    rustPlatform.bindgenHook
  ];
  buildInputs = [
    libnftnl
    libmnl
    dbus
  ];

  # The unit tests make keys in the temp dir; the one that needs root to chown returns early in the sandbox.
  doCheck = true;

  meta = {
    description = "Nostr Vault mesh (FIPS) for a Linux box; runs as its own user, refuses root";
    homepage = "https://github.com/btcforplebs/nostr-vault/tree/master/linux/mesh";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "nv-mesh";
  };
}
