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

Not built yet: the FIPS side. That's fips-ts plus `@fips/tcp` NIP-01 on one service port, with only the owner's
vault allowed in. Design: FINAL DESIGN in the browser-relay plan.

```sh
npm ci
npm run build    # writes ../website/relay/; commit it with the source change
npm run serve    # http://localhost:8787/relay/, beacons go to beacons.jsonl
```
