# sno-core (vendored)

From [arkin0x/sno-core](https://github.com/arkin0x/sno-core) at `ea2c9fdd06b3` (v0.1.24). Its `package.json` gives the licence as MIT, and arkin0x gave Logen permission to use it in Nostr Vault on 2026-10-29.

These are its built ES modules (`npm run build`, TypeScript compiled by `tsc`): `shards.js` (the SNO payload: reading, validation, the frame), `snoPalette.js` + `snoPalette.json` (the 256-colour built-in palette), and `pose.js` (which `shards.js` imports). Nothing in them is changed except a two-line origin header and the dropped source-map line.

The format is DECK-0003 "SNO" of the Cyberspace protocol: https://github.com/arkin0x/cyberspace/blob/master/decks/DECK-0003-sno.md

To update: clone sno-core, `npm install && npm run build`, and copy the same four files from `dist/`.
