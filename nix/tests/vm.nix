# NixOS VM test: the box boots with the vault and the mesh up as two separate users, the mesh key private to the
# mesh's user, and the box API answering only the owner. The checks mirror linux/native/test/install-test.sh.
# Throwaway keys only: the owner is made fresh at boot by keytool, never a real account's.
{
  pkgs,
  nixosModule,
  package,
  keytool,
}:

pkgs.testers.runNixOSTest {
  name = "nostr-vault";

  nodes.box =
    { lib, ... }:
    {
      imports = [ nixosModule ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      environment.systemPackages = [
        keytool
        pkgs.curl
      ];

      services.nostr-vault = {
        enable = true;
        inherit package;
        environmentFile = "/run/nv-test/owner.env";
      };

      # Test fixture: a throwaway owner, made before the vault's first start. The vault gets the npub only; the
      # secret stays in /root for the NIP-98 checks below.
      systemd.services.nv-test-owner = {
        before = [ "nostr-vault-prepare.service" ];
        requiredBy = [ "nostr-vault-prepare.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          mkdir -p /run/nv-test
          set -- $(${lib.getExe keytool} gen)
          umask 077; echo "$1" > /root/owner.sk
          umask 022; echo "$2" > /run/nv-test/owner.npub
          echo "NV_OWNER=$2" > /run/nv-test/owner.env
        '';
      };
    };

  testScript = ''
    import re

    D = "/var/lib/nostr-vault"
    box.start()
    box.wait_for_unit("nostr-vault.service")
    box.wait_for_unit("nostr-vault-mesh.service")

    with subtest("the mesh makes its own key, private to nvmesh"):
        box.wait_until_succeeds(f"test -s {D}/mesh/npub", timeout=120)
        mnpub = box.succeed(f"cat {D}/mesh/npub").strip()
        onpub = box.succeed("cat /run/nv-test/owner.npub").strip()
        print(f"box mesh npub {mnpub}, throwaway owner {onpub}")
        assert re.fullmatch(r"npub1[02-9ac-hj-np-z]{58}", mnpub), mnpub
        assert onpub and mnpub != onpub, "the mesh key must not be the owner's"
        assert box.succeed(f"stat -c '%U %a' {D}/mesh/key").strip() == "nvmesh 700"
        assert box.succeed(f"stat -c '%U %a' {D}/mesh/key/nsec").strip() == "nvmesh 600"
        assert box.succeed(f"stat -c '%U %a' {D}/mesh").strip() == "nvmesh 755"
        assert box.succeed(f"stat -c '%U %a' {D}").strip() == "nvvault 711"
        box.fail(f"runuser -u nvvault -- cat {D}/mesh/key/nsec")
        box.fail(f"runuser -u nvvault -- ls {D}/mesh/key")
        box.fail(f"grep -rqs \"$(cat /root/owner.sk)\" /etc /run/nv-test {D}")

    with subtest("the vault and the mesh run as two users, neither root, no capabilities"):
        vault_users = box.succeed("ps -o user= -C havend,haven-engine | sort -u").split()
        mesh_users = box.succeed("ps -o user= -C nv-mesh | sort -u").split()
        print(f"vault processes run as {vault_users}, mesh as {mesh_users}")
        assert vault_users == ["nvvault"], vault_users
        assert mesh_users == ["nvmesh"], mesh_users
        assert box.succeed("id -u nvvault").strip() != box.succeed("id -u nvmesh").strip()
        box.succeed("id -nG nvmesh | grep -qvw nvvault")
        box.succeed("id -nG nvvault | grep -qvw nvmesh")
        for p in ["havend", "nv-mesh"]:
            box.succeed(f"grep -q 'CapEff:\\s*0000000000000000' /proc/$(pgrep -x {p})/status")

    with subtest("nv-mesh refuses root"):
        out = box.succeed("mkdir -p /tmp/nvroot && NV_DATA_DIR=/tmp/nvroot ${package}/bin/nv-mesh 2>&1 || true")
        assert "refusing to run as root" in out, out
        box.fail("test -e /tmp/nvroot/mesh/key")

    with subtest("ports: 8080 for everyone, engine and mesh door on loopback"):
        box.wait_until_succeeds("ss -Hltn 'sport = :3355' | grep -q .", timeout=120)
        box.wait_until_succeeds("ss -Hltn 'sport = :8081' | grep -q .", timeout=60)
        print(box.succeed("ss -Hltnp | grep -E 'havend|haven-engine|nv-mesh' || true"))
        box.succeed("ss -Hltn 'sport = :8080' | awk '{print $4}' | grep -Eq '^(\\*|0.0.0.0|\\[::\\]):8080'")
        box.fail("ss -Hltn 'sport = :3355' | awk '{print $4}' | grep -vq '^127.0.0.1:'")
        box.fail("ss -Hltn 'sport = :8081' | awk '{print $4}' | grep -vq '^127.0.0.1:'")

    with subtest("web app and box API"):
        box.succeed("curl -fsS http://127.0.0.1:8080/ | grep -qi '<html'")
        U = "http://127.0.0.1:8080/api/box/status"
        code = box.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {U}").strip()
        assert code == "401", f"no auth: {code}"
        code = box.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -H \"Authorization: $(nv-keytool auth $(nv-keytool gen | cut -d' ' -f1) GET {U})\" {U}"
        ).strip()
        assert code == "403", f"stranger: {code}"
        st = box.succeed(f"curl -s -H \"Authorization: $(nv-keytool auth $(cat /root/owner.sk) GET {U})\" {U}")
        print(f"owner status: {st[:400]}")
        assert mnpub in st, "box API should answer the owner with the box npub"

    with subtest("a killed mesh comes back with the same key"):
        box.succeed("kill -9 $(pgrep -x nv-mesh)")
        box.wait_until_succeeds("pgrep -x nv-mesh", timeout=60)
        box.wait_for_unit("nostr-vault-mesh.service")
        assert box.succeed(f"cat {D}/mesh/npub").strip() == mnpub
  '';
}
