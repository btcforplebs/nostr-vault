// Sign-up's Fill Your Feed step (screens/CreateAccount.jsx Follows): a new account follows 5 people before it's ready,
// the iPhone and Android rule (#2601/#2602, Logen 2026-11-26 fc2719f6). No "Continue without follows"; the step says
// how many are left, and Continue stays off until 5.
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
const { Follows, FOLLOWS_NEEDED, followsStillNeeded, followsButtonLabel } = await import("../src/screens/CreateAccount.jsx")
const { starterPacks } = await import("../src/net/new-account.js")

/** Every vnode under `n`, depth first. */
const walk = n => (n == null || typeof n !== "object") ? [] : Array.isArray(n) ? n.flatMap(walk) : [n, ...walk(n.props?.children)]
const text = n => (n == null || typeof n === "boolean") ? "" : typeof n !== "object" ? String(n) : Array.isArray(n) ? n.map(text).join("") : text(n.props?.children)

const packs = starterPacks()
const everyone = packs.flatMap(p => p.accounts.map(a => a.pubkey))
/** The step drawn with the first `n` starter people picked; its Continue button, the count line and the whole text. */
function step(n) {
  let continued = 0
  const tree = Follows({ packs, picked: new Set(everyone.slice(0, n)), setPicked: () => {}, onContinue: () => continued++ })
  const nodes = walk(tree)
  const main = nodes.find(v => v.type === "button" && String(v.props.class).includes("onboard-main"))
  const count = nodes.find(v => String(v.props?.class ?? "").includes("onboard-follow-count"))
  return { main, count, all: text(tree), continued: () => continued }
}

test("5 follows before the account is ready, as on iPhone and Android", () => {
  assert.equal(FOLLOWS_NEEDED, 5)
  assert.deepEqual([0, 1, 4, 5, 9].map(followsStillNeeded), [5, 4, 1, 0, 0])
  assert.equal(followsButtonLabel(0), "Pick 5 more")
  assert.equal(followsButtonLabel(3), "Pick 2 more")
  assert.equal(followsButtonLabel(5), "Continue with 5 people")
})

test("the starter packs offer at least 5 people, so nobody is stuck on the step", () => {
  assert.ok(new Set(everyone).size >= FOLLOWS_NEEDED, `only ${everyone.length} starter people`)
})

test("there is no way past the step with fewer than 5: no skip, Continue off, the count left on screen", () => {
  for (const n of [0, 1, 4]) {
    const s = step(n)
    assert.ok(!/without follows/i.test(s.all), "a skip is offered")
    assert.equal(s.main.props.disabled, true, `Continue on at ${n}`)
    assert.equal(text(s.main.props.children).trim(), `Pick ${5 - n} more`)
    assert.match(text(s.count), new RegExp(`${n} of 5 picked: ${5 - n} more to go`))
    s.main.props.onClick() // a click that gets through anyway (devtools, a stale render) still doesn't continue
    assert.equal(s.continued(), 0)
  }
})

test("at 5 Continue turns on and moves on", () => {
  for (const n of [5, 7]) {
    const s = step(n)
    assert.equal(s.main.props.disabled, false)
    assert.equal(text(s.main.props.children).trim(), `Continue with ${n} people`)
    assert.match(text(s.count), /You're ready/)
    s.main.props.onClick()
    assert.equal(s.continued(), 1)
  }
})
