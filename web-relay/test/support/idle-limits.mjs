// The intervals the two pumps run at, read from the source so this test cannot drift from them.
import { readFileSync } from "node:fs"
const src = f => readFileSync(new URL(`../../src/fips/${f}`, import.meta.url), "utf8")
const POLL = /const POLL_MS = (\d+)/

export const POLL_MS_LIMITS = {
  tcp: Number(src("tcp-server.js").match(POLL)[1]),
  door: Number(src("mesh-door.js").match(POLL)[1]),
  idle: Number(src("pump.js").match(/export const IDLE_MS = (\d+)/)[1]),
}
