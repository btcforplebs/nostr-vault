// After sign-in the vault asks the browser to keep its copy (navigator.storage.persist) and shows the answer.
// Node can't load .jsx, so a load hook compiles it with Vite's Oxc transform via rolldown (same JSX settings as vite.config.js).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { askToKeep, StorageNote } = await import("../src/components/StorageNote.jsx")

function storage(answer) {
  const s = { calls: 0, persist: async () => { s.calls++; return answer } }
  return s
}

test("the browser said yes: kept", async () => {
  const s = storage(true)
  assert.equal(await askToKeep(s), true)
  assert.equal(s.calls, 1)
})

test("the browser said no: may clear it", async () => {
  const s = storage(false)
  assert.equal(await askToKeep(s), false)
  assert.equal(s.calls, 1)
})

test("a persist() that throws counts as no", async () => {
  assert.equal(await askToKeep({ persist: async () => { throw new Error("denied") } }), false)
})

test("no storage API: null, nothing called", async () => {
  assert.equal(await askToKeep(undefined), null)
  assert.equal(await askToKeep({}), null)
  assert.equal(await askToKeep({ persist: "nope" }), null)
})

// The note's text: the warning always, the answer only once it's known.
function text(kept) {
  const flat = n => n == null || n === false ? "" : typeof n === "string" ? n : [n.props?.children].flat().map(flat).join(" ")
  return flat(StorageNote({ kept }))
}

test("the note says the phone's vault is the real one, with the answer when known", () => {
  assert.match(text(undefined), /browser can clear it\. Your phone's vault is the real one/)
  assert.doesNotMatch(text(undefined), /Kept on this browser|may clear it/)
  assert.match(text(true), /Kept on this browser/)
  assert.match(text(false), /This browser may clear it/)
  assert.match(text(null), /This browser may clear it/)
})
