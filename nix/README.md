# Nostr Vault for Nix

The Linux box from `linux/` as a flake: the same programs as the `.deb` (`linux/native/`) and the container, built
by Nix, and a NixOS module that runs them under the same contract. x86_64-linux and aarch64-linux.

| Output | What |
|---|---|
| `packages.<system>.nostr-vault` (`default`) | the whole box: `bin/havend`, `bin/haven-engine`, `bin/nv-mesh`, `libexec/nostr-vault/prepare`, `share/nostr-vault/web` |
| `packages.<system>.nostr-vault-havend` | havend and haven-engine (pure Go, CGO off, engine with `-tags nolmdb`) |
| `packages.<system>.nv-mesh` | the mesh (`linux/mesh`) |
| `packages.<system>.nostr-vault-web` | the web app, box build (`NV_BOX=1`) |
| `nixosModules.default` | `services.nostr-vault` |
| `overlays.default` | the four packages above |
| `checks.<system>.vm` | the NixOS VM test |

## NixOS

```nix
{
  inputs.nostr-vault.url = "github:btcforplebs/nostr-vault";
  outputs = { nixpkgs, nostr-vault, ... }: {
    nixosConfigurations.box = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        nostr-vault.nixosModules.default
        {
          services.nostr-vault = {
            enable = true;
            owner = "npub1…";       # your npub; never an nsec
            openFirewall = true;    # 8080 on the LAN
          };
        }
      ];
    };
  };
}
```

Options: `owner`, `port` (8080; the mesh door is `port`+1 on loopback), `dataDir` (`/var/lib/nostr-vault`),
`moveRoot` (`/mnt`), `openFirewall`, `environmentFile` (a path string outside the Nix store, for secrets such as
backup `NV_S3_*`, or `NV_OWNER`; the vault reads it, the mesh never does; a store path is refused), `settings` (more
`NV_*` for havend, no secrets), `mesh.enable`, `mesh.udpPort`, `mesh.settings` (`NV_MESH_RELAYS`, `NV_MESH_DEVICES`
for nv-mesh, no secrets).

## Two users, one key

As `linux/mesh/README.md` and the `.deb`:

| Unit | Runs | As |
|---|---|---|
| `nostr-vault-prepare` | `linux/native/lib/prepare`, unchanged: data dir 0711 (vault's), `mesh/` 0755 (mesh's) | root, once |
| `nostr-vault` | havend on `port`, engine on 127.0.0.1:3355, mesh door on 127.0.0.1:`port`+1 | `nvvault` |
| `nostr-vault-mesh` | nv-mesh; its key `mesh/key/` (0700, file 0600) | `nvmesh` |

The mesh key is never readable as the vault's user: `mesh/` and `mesh/key/` belong to `nvmesh`, prepare refuses a
`mesh/` that is a symlink or belongs to anyone else (the vault owns the data dir and could plant one), and nv-mesh
refuses a key that is a symlink, another uid's, or can't be made 0600. The module refuses to evaluate if
`nostr-vault-mesh` is set to run as anyone but `nvmesh`, if either user has uid 0 or both share a uid, or if the two
share a group (`group`, `extraGroups`, `users.groups.*.members`, or a unit's `Group`/`SupplementaryGroups`) or sit
in `root`/`wheel`. nv-mesh itself exits at start as root. Both services: no capabilities, no new
privileges, `ProtectSystem=strict` with only their own folders writable, the container's memory caps.

User names are fixed (`nvvault`, `nvmesh`) because prepare looks them up by name. Their uids are NixOS's system
uids, not the container's 10002/10001.

## Build and test

```sh
nix build .#nostr-vault
nix flake check -L          # builds everything and runs the VM test
nix build -L .#checks.x86_64-linux.vm
```

The VM test boots a box with a throwaway owner (keytool, made at boot) and checks what
`linux/native/test/install-test.sh` checks: the vault and the mesh as two users with no capabilities, the key's
owner and modes, the vault's user can't read it, nv-mesh refuses root, the loopback-only engine and mesh door, the
box API's 401/403/owner answers, and a killed nv-mesh comes back with the same npub. CI:
`.github/workflows/nix.yml`, on an x86_64 and an aarch64 runner.

## When a lockfile changes

The Nix build pins the fixed-output hashes of every dependency set: `vendorHash` (havend, keytool), the two npm
`hash`es (web), and the git dep's `outputHashes` (nv-mesh). A change to `haven-go/go.sum`, a `package-lock.json`
or `linux/mesh/Cargo.lock` moves one of them, and the Nix workflow fails with `hash mismatch … got: sha256-…`. Put
the `got:` value in the file under `nix/packages/` it names.
