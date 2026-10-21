# fips-v2 (spike)

Milestone-1 probe for Nostr Vault FIPS v2: upstream jmcorgan/fips v0.5.2 embedded
in-process, app-owned TUN, smoltcp userspace TCP/IP. No VPN, no system TUN, no seed.

```sh
cargo build --release
# side A: expose a local relay/HTTP server on mesh port 80
fipsv2-probe serve   --peer <npub-of-B> --forward 127.0.0.1:3355 --state .a
# side B: local port that tunnels to A's mesh port 80
fipsv2-probe connect --peer <npub-of-A> --listen 127.0.0.1:4000 --state .b
curl http://127.0.0.1:4000/   # or ws://127.0.0.1:4000 for a relay
```

`serve` takes `--peer` once per own device: only those reach `--forward`, and only their
traversal offers are answered. On the Mac, `--forward` is the Mac relay (127.0.0.1:3355).

```sh
# also let anyone read a blob by hash, through the public seeds only
fipsv2-probe serve --peer <npub-of-phone> --peer <npub-of-ipad> --forward 127.0.0.1:3355 --blobs
```

`--blobs` links to the public seeds (as a leaf) and sends everyone who is not an own device
to a blob gate: `GET`/`HEAD /<sha256>[.ext]` is fetched from `--forward`, checked against the
hash, and passed on with its type and length only. Anything else (`/`, `/list/..`, upload,
WebSocket) gets 404/405 and never reaches the relay. Readers come through the seeds and never
link directly, so they never see this machine's address. No `Range` yet.

Each side prints its npub on start (identity kept in `<state>/nsec`). `--lan` shares
private candidates (same-LAN tests). `FIPSV2_PKTLOG=1` logs every TCP packet.
Plan: ~/.buzz/PLANS/NOSTR_VAULT_FIPS_V2_FROM_UPSTREAM.md
