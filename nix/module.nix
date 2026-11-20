# NixOS module: Nostr Vault on a box, the same contract as the native .deb (linux/native/systemd) and the container
# (linux/mesh/README.md):
#
#   nostr-vault-prepare  root, once: the data dir (nvvault, 0711) and mesh/ (nvmesh, 0755). linux/native/lib/prepare,
#                        unchanged: it never follows a link the vault planted and never takes over a mesh/ the vault made.
#   nostr-vault          havend as nvvault: relay, Blossom, web app, box API on `port`; the engine on 127.0.0.1:3355,
#                        the mesh door on 127.0.0.1:`port`+1.
#   nostr-vault-mesh     nv-mesh as nvmesh: the box's mesh key in mesh/key/ (dir 0700, file 0600, readable by nvmesh
#                        alone). Never root, never the vault's user or group; nv-mesh itself refuses root too.
#
# The two users are fixed names because prepare looks them up by name (`id -u nvvault`, `id -u nvmesh`).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nostr-vault;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkPackageOption
    types
    ;

  vaultUser = "nvvault";
  meshUser = "nvmesh";
  doorPort = cfg.port + 1;

  common = {
    NV_DATA_DIR = cfg.dataDir;
    NV_PORT = toString cfg.port;
    NV_MESH_DOOR_PORT = toString doorPort;
  };

  # As the .deb's units: no capabilities, no new privileges, a read-only system with only their own folders writable.
  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
      "AF_NETLINK"
    ];
    UMask = "0022";
    Restart = "always";
    RestartSec = 2;
    Nice = 10;
    CPUWeight = 25;
  };

  # Every group a user is in: its own, extraGroups, and any users.groups.<g>.members that names it.
  groupsOf =
    name:
    [ config.users.users.${name}.group ]
    ++ config.users.users.${name}.extraGroups
    ++ lib.attrNames (lib.filterAttrs (_: g: lib.elem name g.members) config.users.groups);
  # The groups a unit runs with: Group plus SupplementaryGroups.
  unitGroups =
    unit:
    let
      sc = config.systemd.services.${unit}.serviceConfig;
    in
    lib.toList (sc.Group or [ ]) ++ lib.concatMap lib.toList (lib.toList (sc.SupplementaryGroups or [ ]));
  meshUid = config.users.users.${meshUser}.uid;
  vaultUid = config.users.users.${vaultUser}.uid;
  privileged = [
    "root"
    "wheel"
  ];
in
{
  options.services.nostr-vault = {
    enable = mkEnableOption "Nostr Vault, a personal Nostr relay and media vault with its own mesh";

    package = mkPackageOption pkgs "nostr-vault" { };

    owner = mkOption {
      type = types.nullOr (types.strMatching "npub1[02-9ac-hj-np-z]{58}|[0-9a-f]{64}");
      default = null;
      example = "npub1…";
      description = ''
        The vault's owner (npub or hex public key). Never a secret key: no nsec of the owner's is ever on the box.
        Leave null only when {option}`services.nostr-vault.environmentFile` sets `NV_OWNER`.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "havend's port: relay, Blossom, web app and box API. The mesh door is this port + 1, on loopback.";
    };

    dataDir = mkOption {
      type = types.strMatching "/.*[^/]";
      default = "/var/lib/nostr-vault";
      description = "The vault's data. mesh/ inside it is the mesh's (its key in mesh/key/).";
    };

    moveRoot = mkOption {
      type = types.str;
      default = "/mnt";
      description = "Where Storage › Move vault may move the data (NV_MOVE_ROOT).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open {option}`port` (TCP), and the mesh UDP port when it is fixed.";
    };

    environmentFile = mkOption {
      # A string, not a path: a path literal (./secrets.env) would be copied into the world-readable Nix store.
      type = types.nullOr (types.strMatching "/.*");
      default = null;
      description = ''
        Extra settings for the vault (systemd EnvironmentFile), e.g. backup `NV_S3_*` secrets or `NV_OWNER`. Read by
        the vault only, never by the mesh. A full path outside the Nix store (the module refuses a store path).
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        NV_DIRECTORY_RELAYS = "wss://relay.example";
      };
      description = "Extra environment for havend (no secrets: it lands in the Nix store).";
    };

    mesh = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run nv-mesh, so the owner's devices reach the box over FIPS.";
      };
      settings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          NV_MESH_RELAYS = "wss://relay.example";
        };
        description = ''
          Extra environment for nv-mesh, e.g. `NV_MESH_RELAYS` or `NV_MESH_DEVICES` (linux/mesh/README.md). No
          secrets: it lands in the Nix store.
        '';
      };
      udpPort = mkOption {
        type = types.port;
        default = 0;
        description = "The mesh UDP port (NV_MESH_UDP_PORT); 0 lets the OS pick.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.owner != null || cfg.environmentFile != null;
        message = "services.nostr-vault: set owner (an npub), or NV_OWNER in environmentFile.";
      }
      {
        assertion = cfg.environmentFile == null || !lib.hasPrefix "${builtins.storeDir}/" cfg.environmentFile;
        message = "services.nostr-vault.environmentFile: ${toString cfg.environmentFile} is in the Nix store, which anyone on the box can read; put it outside.";
      }
      {
        assertion = cfg.port < 65535;
        message = "services.nostr-vault.port: the mesh door needs port + 1.";
      }
      # The mesh key must never be reachable as the vault's user, and nv-mesh never runs as root.
      {
        assertion = !cfg.mesh.enable || config.systemd.services.nostr-vault-mesh.serviceConfig.User == meshUser;
        message = "services.nostr-vault: nostr-vault-mesh must run as ${meshUser}, not root or the vault's user.";
      }
      {
        assertion = config.systemd.services.nostr-vault.serviceConfig.User == vaultUser;
        message = "services.nostr-vault: nostr-vault must run as ${vaultUser}.";
      }
      {
        # null = NixOS picks a free system uid (never 0, never the other's).
        assertion = meshUid != 0 && vaultUid != 0 && (meshUid == null || meshUid != vaultUid);
        message = "services.nostr-vault: ${meshUser} and ${vaultUser} need two different non-root uids.";
      }
      {
        assertion =
          !(lib.elem config.users.users.${meshUser}.group (groupsOf vaultUser))
          && !(lib.elem config.users.users.${vaultUser}.group (groupsOf meshUser))
          && lib.intersectLists privileged (groupsOf meshUser ++ groupsOf vaultUser) == [ ];
        message = "services.nostr-vault: ${meshUser} and ${vaultUser} must share no group, and neither may be in root or wheel.";
      }
      {
        # The same for the units' own Group and SupplementaryGroups, which can add groups the users don't have.
        assertion =
          unitGroups "nostr-vault" == [ vaultUser ]
          && (!cfg.mesh.enable || unitGroups "nostr-vault-mesh" == [ meshUser ]);
        message = "services.nostr-vault: nostr-vault must run with group ${vaultUser} only, and nostr-vault-mesh with ${meshUser} only (no SupplementaryGroups).";
      }
    ];

    users.users.${vaultUser} = {
      isSystemUser = true;
      group = vaultUser;
      description = "Nostr Vault";
    };
    users.groups.${vaultUser} = { };
    users.users.${meshUser} = {
      isSystemUser = true;
      group = meshUser;
      description = "Nostr Vault mesh";
    };
    users.groups.${meshUser} = { };

    systemd.services.nostr-vault-prepare = {
      description = "Nostr Vault: set up the data folder";
      environment.NV_DATA_DIR = cfg.dataDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/libexec/nostr-vault/prepare";
      };
    };

    systemd.services.nostr-vault = {
      description = "Nostr Vault";
      documentation = [ "https://github.com/btcforplebs/nostr-vault/tree/master/linux" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ] ++ lib.optional cfg.mesh.enable "nostr-vault-mesh.service";
      after = [
        "network-online.target"
        "nostr-vault-prepare.service"
      ];
      requires = [ "nostr-vault-prepare.service" ];
      environment =
        common
        // {
          HAVEN_MESH_PLAIN_PORT = toString doorPort;
          NV_WEB_DIR = "${cfg.package}/share/nostr-vault/web";
          NV_ENGINE_BIN = "${cfg.package}/bin/haven-engine";
          NV_MOVE_ROOT = cfg.moveRoot;
          NV_VERSION = cfg.package.version;
        }
        // lib.optionalAttrs (cfg.owner != null) { NV_OWNER = cfg.owner; }
        // cfg.settings;
      serviceConfig = hardening // {
        Type = "simple";
        User = vaultUser;
        Group = vaultUser;
        ExecStart = "${cfg.package}/bin/havend";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        MemoryMax = "1536M";
        ReadWritePaths = [
          "-${cfg.dataDir}"
          "-${cfg.moveRoot}"
        ];
      };
    };

    systemd.services.nostr-vault-mesh = mkIf cfg.mesh.enable {
      description = "Nostr Vault mesh";
      documentation = [ "https://github.com/btcforplebs/nostr-vault/tree/master/linux/mesh" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nostr-vault-prepare.service"
      ];
      requires = [ "nostr-vault-prepare.service" ];
      partOf = [ "nostr-vault.service" ];
      environment =
        common
        // {
          NV_MESH_UDP_PORT = toString cfg.mesh.udpPort;
        }
        // cfg.mesh.settings;
      serviceConfig = hardening // {
        Type = "simple";
        User = meshUser;
        Group = meshUser;
        ExecStart = "${cfg.package}/bin/nv-mesh";
        MemoryMax = "512M";
        # Only mesh/ is writable; it reads mesh-devices.json (havend's) from the data dir.
        ReadWritePaths = [ "-${cfg.dataDir}/mesh" ];
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
      allowedUDPPorts = lib.optional (cfg.mesh.enable && cfg.mesh.udpPort != 0) cfg.mesh.udpPort;
    };
  };
}
