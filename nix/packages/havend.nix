# havend (the box daemon) and haven-engine (the vault relay it supervises), built as linux/native/build.sh and
# linux/Dockerfile build them: pure Go, CGO off, the engine with -tags nolmdb (Badger only, as libhaven on the Mac).
{
  lib,
  buildGoModule,
  src,
  version,
  commit ? "unknown",
}:

buildGoModule {
  pname = "nostr-vault-havend";
  inherit version src;
  modRoot = "haven-go";

  # haven-go/go.mod has `replace` lines into ./third_party, which go mod vendor copies in.
  vendorHash = "sha256-Jz7CFclJPvrhstiJJ6JFuc5I0resnrVWrA7Z0L9GicI=";

  env.CGO_ENABLED = 0;
  # havend has no nolmdb build tag of its own; the tag only drops LMDB from the engine (init_lmdb.go).
  tags = [ "nolmdb" ];
  subPackages = [
    "cmd/havend"
    "."
  ];
  ldflags = [
    "-s"
    "-w"
    "-X 'main.version=${version} (${commit})'"
  ];

  # The root package is `main` with module path github.com/barrydeen/haven, so go install names it `haven`.
  postInstall = ''
    mv $out/bin/haven $out/bin/haven-engine
  '';

  # The haven-go suite has live tests that dial public relays; the NixOS VM test (nix/tests/vm.nix) runs the
  # built programs end to end instead.
  doCheck = false;

  meta = {
    description = "Nostr Vault box daemon (havend) and vault relay engine (haven-engine)";
    homepage = "https://github.com/btcforplebs/nostr-vault";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "havend";
  };
}
