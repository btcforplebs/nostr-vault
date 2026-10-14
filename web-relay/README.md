# web-relay

A Nostr relay that runs inside a browser page. It's served as a static PWA at `https://nostrvault.app/relay/`
(the files in `website/relay/`, built from here).

- The relay is **Haven** (`../haven-go`) built for js/wasm, running in the page with an IndexedDB store per route.
  `src/haven/haven.js` loads `haven.wasm` and wraps its entry point (`havenStart` / `havenConn` / `havenStop`).
  Haven takes its owner at start: the first paired owner npub. Other owners, and the page's throwaway test key,
  are whitelisted. Changing owners reloads the page.
- The page talks to Haven like any client, over its own NDJSON stream on the outbox route (`src/haven/client.js`).
- `main.js` runs the page:
  - "Start screensaver" holds a Screen Wake Lock and shows the event count and uptime.
  - It calls `navigator.storage.persist()`.
  - **Report** gives quota, persistence, the signature self-test, and the gaps in uptime.
- The measurement generator is off by default. When it's on, it writes one test note every 10s from a throwaway
  key kept on the device. Gaps in those timestamps show how long the page wasn't running.

**FIPS (G3, `src/fips/`).** The page runs a non-forwarding fips-ts node on the main thread.
- First route: the public iris seeds over WSS. WebRTC offers are accepted only from owners.
- It serves NIP-01 over TCP/FIPS (`@fips/tcp`) on FSP service port **7447**. Framing is NDJSON: one JSON array per `\n`-terminated line.
  Each TCP connection becomes one Haven stream in `nip01` mode on the outbox route `/`. The page picks the route; the stream can't.
- Only owner npubs get past the datagram gate (`ownerGatedEndpoint`), so a stranger's SYN never gets a reply.
- Pair by pasting the vault npub, or with `nostrvault.app/relay/#owner=npub1…`.
- fips-ts and fips-tcp come from GitHub release tarballs, pinned by sha512 in `package-lock.json`.

```sh
npm ci
tools/build-haven-wasm.sh   # haven-go -> public/haven.wasm + src/haven/wasm_exec.js (needs Go)
npm run build    # writes ../website/relay/, built at deploy time and not committed (.gitignore)
npm run serve    # http://localhost:8787/relay/, beacons go to beacons.jsonl
npm test         # TCP/FIPS server + page client against a contract stub; the real haven.wasm under node when built
node tools/vault-sim.mjs <secretHex> <relayNpub>   # stand-in vault over the public seed: REQ -> EOSE
```

Nothing builds `website/relay/` automatically yet: a fresh clone serves `/relay/` as 404 until `npm run build` runs.
