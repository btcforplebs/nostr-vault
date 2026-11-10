// A link card's OpenGraph preview is this browser fetching the page: for a stranger's note in the Vault lists that is
// the IP leak itself. Here LinkCard's effect runs (preact/hooks stubbed, effects run at once) against a stand-in
// link-preview.js that counts loadPreview calls, so the test fails if the effect stops honouring `load`.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

const mod = src => "data:text/javascript," + encodeURIComponent(src)
const HOOKS = mod(`
  export const useState = i => [typeof i === "function" ? i() : i, () => {}]
  export const useEffect = f => { f() }
  export const useRef = v => ({ current: v ?? null })`)
const PREVIEW = mod(`
  globalThis.previewCalls = []
  export const cachedPreview = () => undefined
  export const canPreview = url => /^https:/.test(url)
  export const loadPreview = url => { globalThis.previewCalls.push(url); return new Promise(() => {}) }`)
registerHooks({
  resolve(spec, context, next) {
    if (spec === "preact/hooks" && context.parentURL?.endsWith("/LinkCard.jsx")) return { url: HOOKS, shortCircuit: true }
    if (spec === "./link-preview.js" && context.parentURL?.endsWith("/LinkCard.jsx")) return { url: PREVIEW, shortCircuit: true }
    return next(spec, context)
  },
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { LinkCard } = await import("../src/components/LinkCard.jsx")

test("LinkCard off never asks the page for its preview; on, it does", () => {
  const url = "https://tracker.example/page"
  globalThis.previewCalls.length = 0
  LinkCard({ url, load: false })
  assert.deepEqual(globalThis.previewCalls, [], "no OpenGraph fetch for a stranger's link")
  LinkCard({ url })
  assert.deepEqual(globalThis.previewCalls, [url], "the stand-in sees the fetch, so the test can fail")
})
