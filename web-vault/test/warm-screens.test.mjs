// Warming the tab screens' chunks while the app is idle: once per page, one at a time, never on a data saver or 2G.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { warmScreens, resetWarm, lightLink, WARM_ORDER } = await import("../src/screens/warm-screens.js")

const fake = (name, log, fail = false) => ({ load: async () => { log.push(`start ${name}`); await null; log.push(`end ${name}`); if (fail) throw new Error("x") } })
const now = () => Promise.resolve()

test("warms each screen once, one after another, and only once per page", async () => {
  resetWarm()
  const log = []
  const screens = ["a", "b", "c"].map(n => fake(n, log, n === "b"))
  await warmScreens({ screens, nav: {}, wait: now, idle: now })
  assert.deepEqual(log, ["start a", "end a", "start b", "end b", "start c", "end c"], "one at a time, a failed one doesn't stop the rest")
  assert.equal(warmScreens({ screens, nav: {}, wait: now, idle: now }), null, "a second call does nothing")
})

test("a data saver or a 2G link warms nothing", () => {
  for (const connection of [{ saveData: true }, { effectiveType: "2g" }, { effectiveType: "slow-2g" }]) {
    resetWarm()
    assert.equal(lightLink({ connection }), true)
    assert.equal(warmScreens({ screens: [fake("a", [])], nav: { connection }, wait: now, idle: now }), null)
  }
  assert.equal(lightLink({ connection: { effectiveType: "4g" } }), false)
  assert.equal(lightLink({}), false)
})

test("the real list is the tab screens, each with a load()", () => {
  assert.ok(WARM_ORDER.length >= 6)
  for (const s of WARM_ORDER) assert.equal(typeof s.load, "function")
})
