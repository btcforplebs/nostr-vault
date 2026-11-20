# The whole box in one package, laid out for the NixOS module (nix/module.nix):
#   bin/havend, bin/haven-engine, bin/nv-mesh
#   libexec/nostr-vault/prepare   linux/native/lib/prepare, the root step that sets up the data dir
#   share/nostr-vault/web         the web app havend serves
{
  lib,
  runCommand,
  makeWrapper,
  coreutils,
  findutils,
  getent,
  havend,
  nv-mesh,
  web,
  src,
  version,
}:

runCommand "nostr-vault-${version}"
  {
    inherit version;
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit havend nv-mesh web; };
    meta = {
      description = "Nostr Vault for a Linux box: the vault (havend), its mesh (nv-mesh) and web app";
      homepage = "https://github.com/btcforplebs/nostr-vault";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "havend";
    };
  }
  ''
    mkdir -p $out/bin $out/libexec/nostr-vault $out/share/nostr-vault
    ln -s ${havend}/bin/havend ${havend}/bin/haven-engine ${nv-mesh}/bin/nv-mesh $out/bin/
    ln -s ${web}/share/nostr-vault/web $out/share/nostr-vault/web
    # prepare is plain sh and reads the users from the passwd db (id, getent), as on Debian.
    install -m 755 ${src}/linux/native/lib/prepare $out/libexec/nostr-vault/.prepare-wrapped
    patchShebangs $out/libexec/nostr-vault/.prepare-wrapped
    makeWrapper $out/libexec/nostr-vault/.prepare-wrapped $out/libexec/nostr-vault/prepare \
      --set PATH ${
        lib.makeBinPath [
          coreutils
          findutils
          getent
        ]
      }
  ''
