# The module must refuse to build a system where the mesh's key could be read as the vault's user or where nv-mesh
# runs as root. Each bad config below must fail to evaluate; the good one (the positive control) must evaluate, so
# this check can't pass just because every config breaks for some other reason.
{
  pkgs,
  lib,
  nixosSystem,
  nixosModule,
  package,
}:

let
  toplevel =
    extra:
    (nixosSystem {
        inherit (pkgs.stdenv.hostPlatform) system;
        modules = [
          nixosModule
          {
            boot.loader.grub.enable = false;
            fileSystems."/".device = "/dev/null";
            system.stateVersion = "26.05";
            services.nostr-vault = {
              enable = true;
              inherit package;
              # A syntactically valid npub; it is never run, only evaluated.
              owner = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzqujme";
            };
          }
          extra
        ];
      }).config.system.build.toplevel.drvPath;
  evalsOk = extra: (builtins.tryEval (toplevel extra)).success;
  # The positive control is evaluated outside tryEval: if it breaks, the error itself shows instead of a bare false.
  control = builtins.seq (toplevel { }) true;

  cases = {
    "good config (positive control)" = {
      want = true;
      cfg = { };
    };
    "mesh as root" = {
      want = false;
      cfg.systemd.services.nostr-vault-mesh.serviceConfig.User = lib.mkForce "root";
    };
    "mesh as the vault's user" = {
      want = false;
      cfg.systemd.services.nostr-vault-mesh.serviceConfig.User = lib.mkForce "nvvault";
    };
    "vault as root" = {
      want = false;
      cfg.systemd.services.nostr-vault.serviceConfig.User = lib.mkForce "root";
    };
    "mesh uid 0" = {
      want = false;
      cfg.users.users.nvmesh.uid = 0;
    };
    "mesh and vault share a uid" = {
      want = false;
      cfg.users.users = {
        nvmesh.uid = 990;
        nvvault.uid = 990;
      };
    };
    "vault in the mesh's group" = {
      want = false;
      cfg.users.users.nvvault.extraGroups = [ "nvmesh" ];
    };
    "mesh in wheel" = {
      want = false;
      cfg.users.users.nvmesh.extraGroups = [ "wheel" ];
    };
    "no owner at all" = {
      want = false;
      cfg.services.nostr-vault.owner = lib.mkForce null;
    };
  };

  results = lib.mapAttrsToList (
    name: c:
    let
      got = if c.want then control else evalsOk c.cfg;
    in
    {
      inherit name;
      ok = got == c.want;
      line = "${if got == c.want then "PASS" else "FAIL"}: ${name} (evaluates: ${lib.boolToString got}, want ${lib.boolToString c.want})";
    }
  ) cases;
in
pkgs.runCommand "nostr-vault-module-assertions" { } ''
  cat <<'EOF'
  ${lib.concatMapStringsSep "\n" (r: r.line) results}
  EOF
  ${if lib.all (r: r.ok) results then "touch $out" else "exit 1"}
''
