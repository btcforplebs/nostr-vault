Vendored from `@snort/worker-relay` 3.0.1 (MIT, Kieran, https://git.v0l.io/Kieran/snort).

Local change: `verify.ts` checks NIP-01 id + BIP-340 signature. It runs on the `event` command
(the worker leader and the follower proxy both reply `OK false "invalid: ..."`) and in
`SqliteRelay.#insertEvent`, which every write path goes through.
