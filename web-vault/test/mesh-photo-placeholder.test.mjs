// While a photo reads over the mesh, MediaImage draws a box that says so (never the dead https image's broken icon),
// and says the owner's vault couldn't be reached when the read gives up. Vnodes only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { MeshBox, LOADING_TEXT, UNREACHED_TEXT } = await import("../src/components/MediaImage.jsx")
const { Spinner } = await import("../src/components/Loading.jsx")

const kids = n => [n?.props?.children].flat(Infinity).filter(Boolean)
const text = n => (typeof n === "string" ? n : kids(n).map(text).join(""))
const item = { url: "https://media.example/x.png", width: 4, height: 3 }

test("loading: a status box with a spinner and 'Loading image over the mesh…', in the photo's own shape", () => {
  const v = MeshBox({ state: "wait", item })
  assert.equal(v.type, "span")
  assert.equal(v.props.role, "status")
  assert.equal(text(v), "Loading image over the mesh…")
  assert.equal(LOADING_TEXT, "Loading image over the mesh…")
  assert.ok(kids(v).some(k => k.type === Spinner), "a spinner")
  assert.deepEqual(v.props.style, { aspectRatio: "4 / 3" })
  assert.doesNotMatch(v.props.class, /failed/)
})

test("the read gave up: 'Couldn't reach the owner's vault', no spinner, the reason as its tooltip", () => {
  const v = MeshBox({ state: "unreached", item, why: "no route" })
  assert.equal(text(v), "Couldn't reach the owner's vault")
  assert.equal(UNREACHED_TEXT, "Couldn't reach the owner's vault")
  assert.ok(!kids(v).some(k => k.type === Spinner))
  assert.match(v.props.class, /failed/)
  assert.equal(v.props.title, "no route")
})

test("never read (mesh off for this note): says it isn't reachable, not that the vault was tried", () => {
  const v = MeshBox({ state: "failed", item: { url: "x" } })
  assert.equal(text(v), "Photo not reachable")
  assert.equal(v.props.title, "Photo not reachable")
})
