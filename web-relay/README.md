# web-relay

A Nostr relay that runs inside a browser page. It's served as a static PWA at `https://nostrvault.app/relay/`
(the files in `website/relay/`, built from here).

- `src/worker-relay/` is vendored from `@snort/worker-relay` 3.0.1 (MIT), a NIP-01 store on SQLite-wasm in OPFS.
  Local change: `verify.ts` checks each event's id and BIP-340 signature before it's stored (see `src/worker-relay/README.md`).
- `main.js` runs the page:
  - "Start screensaver" holds a Screen Wake Lock and shows the event count and uptime.
  - It calls `navigator.storage.persist()`.
  - **Report** gives quota, persistence, the signature self-test, and the gaps in uptime.
- The measurement generator is off by default. When it's on, it writes one test note every 10s from a throwaway
  key kept on the device. Gaps in those timestamps show how long the page wasn't running.

**FIPS (G3, `src/fips/`).** The page runs a non-forwarding fips-ts node on the main thread.
- First route: the public iris seeds over WSS. WebRTC offers are accepted only from owners.
- It serves NIP-01 over TCP/FIPS (`@fips/tcp`) on FSP service port **7447**. Framing is NDJSON: one JSON array per `\n`-terminated line, max 512 KiB.
- Only owner npubs get past the datagram gate (`ownerGatedEndpoint`), so a stranger's SYN never gets a reply.
- Pair by pasting the vault npub, or with `nostrvault.app/relay/#owner=npub1…`.
- fips-ts and fips-tcp come from GitHub release tarballs, pinned by sha512 in `package-lock.json`.

```sh
npm ci
npm run build    # writes ../website/relay/; commit it with the source change
npm run serve    # http://localhost:8787/relay/, beacons go to beacons.jsonl
npm test         # TCP/FIPS NIP-01 server: owner, stranger, 15% loss, oversized line
node tools/vault-sim.mjs <secretHex> <relayNpub>   # stand-in vault over the public seed: REQ -> EOSE
```
