{
  # Nostr Vault for Nix: the Linux box (havend + haven-engine, nv-mesh, the web app) and a NixOS module.
  # See nix/README.md.
  description = "Nostr Vault: a personal Nostr relay and media vault, for Linux and NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The app's MARKETING_VERSION (as linux/native/build.sh), plus the commit date.
      marketing = lib.head (
        lib.concatMap (l: lib.optionals (builtins.match " *MARKETING_VERSION:.*" l != null) (
          builtins.match " *MARKETING_VERSION: *\"?([0-9.]+)\"?" l
        )) (lib.splitString "\n" (builtins.readFile ./HavenApp/project.yml))
      );
      version = "${marketing}-unstable-${lib.substring 0 8 (self.lastModifiedDate or "19700101")}";
      commit = self.shortRev or self.dirtyShortRev or "unknown";

      # Only what the builds read, so an app or docs change doesn't rebuild the box.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./haven-go
          ./web-relay
          ./web-vault
          ./web-relay-vault
          ./fips-v2-android
          ./fips-v2/src/stack.rs
          ./linux/mesh
          ./linux/native/lib/prepare
          ./linux/native/test/keytool
        ];
      };

      overlay = final: _prev: {
        nostr-vault-havend = final.callPackage ./nix/packages/havend.nix { inherit src version commit; };
        nv-mesh = final.callPackage ./nix/packages/nv-mesh.nix { inherit src version; };
        nostr-vault-web = final.callPackage ./nix/packages/web.nix {
          inherit src version commit;
          havend = final.nostr-vault-havend;
        };
        nostr-vault = final.callPackage ./nix/packages/nostr-vault.nix {
          inherit src version;
          havend = final.nostr-vault-havend;
          nv-mesh = final.nv-mesh;
          web = final.nostr-vault-web;
        };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        pkgs:
        let
          # The overlay on this system's nixpkgs, so the packages build exactly as an overlay user gets them.
          p = pkgs.extend overlay;
        in
        {
          inherit (p)
            nostr-vault
            nostr-vault-havend
            nv-mesh
            nostr-vault-web
            ;
          default = p.nostr-vault;
          # Test only: throwaway keys for the VM test.
          keytool = p.callPackage ./nix/packages/keytool.nix { inherit src; };
        }
      );

      nixosModules.default =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.nostr-vault.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.nostr-vault;
        };
      nixosModules.nostr-vault = self.nixosModules.default;

      checks = forAllSystems (
        pkgs:
        let
          ps = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          inherit (ps)
            nostr-vault
            nostr-vault-havend
            nv-mesh
            nostr-vault-web
            ;
          module-assertions = import ./nix/tests/module-assertions.nix {
            inherit pkgs lib;
            inherit (nixpkgs.lib) nixosSystem;
            nixosModule = self.nixosModules.default;
            package = ps.nostr-vault;
          };
          vm = import ./nix/tests/vm.nix {
            inherit pkgs;
            nixosModule = self.nixosModules.default;
            package = ps.nostr-vault;
            inherit (ps) keytool;
          };
        }
      );
    };
}
