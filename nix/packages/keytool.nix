# Throwaway keys for the VM test (linux/native/test/keytool): `gen` and a NIP-98 `auth` header. Test only; never a
# real account's key.
{ buildGoModule, src }:

buildGoModule {
  pname = "nostr-vault-test-keytool";
  version = "0";
  inherit src;
  modRoot = "linux/native/test/keytool";
  vendorHash = "sha256-sGk1jI+4/fZw7eSrR7fNJgwsHffhVbwwx53Hb8XAOj4=";
  env.CGO_ENABLED = 0;
  postInstall = ''
    mv $out/bin/keytool $out/bin/nv-keytool
  '';
  meta.mainProgram = "nv-keytool";
}
