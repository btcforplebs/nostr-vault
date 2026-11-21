// Avatar.jsx and constellation faces: a profile with no picture draws its constellation (nothing fetched); a gated
// stranger and a profile not loaded yet keep the plain disc. preact/hooks is stubbed (state is its first value,
// effects don't run), so Avatar is called once as a plain function.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

const HOOKS = "data:text/javascript," + encodeURIComponent(`
  export const useState = i => [typeof i === "function" ? i() : i, () => {}]
  export const useEffect = () => {}, useLayoutEffect = () => {}, useContext = () => undefined
  export const useRef = v => ({ current: v ?? null }), useMemo = f => f(), useCallback = f => f`)
registerHooks({
  resolve(spec, context, next) {
    if (spec === "preact/hooks" && context.parentURL?.includes("/src/")) return { url: HOOKS, shortCircuit: true }
    return next(spec, context)
  },
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { Avatar } = await import("../src/components/Avatar.jsx")
const { putProfile } = await import("../src/net/profiles.js")
const { constellationUrl } = await import("../src/components/constellation.js")

const NO_PIC = "a1".repeat(32), WITH_PIC = "b2".repeat(32), UNKNOWN = "c3".repeat(32)
putProfile({ kind: 0, pubkey: NO_PIC, created_at: 1, content: JSON.stringify({ name: "no picture" }), tags: [] })
putProfile({ kind: 0, pubkey: WITH_PIC, created_at: 1, content: JSON.stringify({ name: "pic", picture: "https://media.example/p.jpg" }), tags: [] })

test("a profile with no picture draws its constellation, at the avatar's size, nothing fetched", () => {
  const v = Avatar({ pubkey: NO_PIC, size: 30 })
  assert.equal(v.type, "img")
  assert.equal(v.props.src, constellationUrl(NO_PIC))
  assert.match(v.props.src, /^data:image\/svg\+xml/)
  assert.deepEqual(v.props.style, { width: 30, height: 30 })
  assert.match(v.props.class, /avatar-stars/)
})

test("a gated stranger keeps the plain disc, with or without a picture (Logen decides that one later)", () => {
  for (const pk of [NO_PIC, WITH_PIC]) {
    const v = Avatar({ pubkey: pk, size: 30, load: false })
    assert.equal(v.type, "div")
    assert.match(v.props.class, /avatar-blank/)
  }
})

test("before the profile arrives the plain disc stays (no constellation flashing before a real picture)", () => {
  const v = Avatar({ pubkey: UNKNOWN, size: 30 })
  assert.equal(v.type, "div")
  assert.match(v.props.class, /avatar-blank/)
})

test("a profile with a picture still draws the picture path, not the constellation", () => {
  const v = Avatar({ pubkey: WITH_PIC, size: 30 })
  assert.doesNotMatch(String(v.props.src ?? ""), /^data:image\/svg/)
  assert.doesNotMatch(v.props.class, /avatar-stars|avatar-blank/)
})
