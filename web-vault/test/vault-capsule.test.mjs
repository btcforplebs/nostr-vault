// The floating "Vault" capsule (components/VaultButton.jsx; styles/settings.css) draws the app's relay state bottom
// right. It is a small pill and stays one: on 2026-11-10 it drew as a 496 x viewport-tall green stadium over the feed
// because its desktop modifier was the bare class `desk`, and desktop.css:12's `.desk` — the desktop shell's own grid,
// `display: grid; height: 100dvh` — matched it. Same specificity, later in the cascade, so it took the capsule's
// height and display away (Logen's Safari screenshot, 1376 x 1032).
//
// The rule this holds to: a class the capsule carries may not also be a class that lays out some other box. A
// modifier may move the capsule; it may not resize it.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const SRC = fileURLToPath(new URL("../src", import.meta.url))
const read = p => readFileSync(join(SRC, p), "utf8")

/** Every class the capsule can carry: `.vault-status`, a connection state, and the desktop modifier. */
export function capsuleClasses({ button = read("components/VaultButton.jsx"), color = read("net/connection-color.js") } = {}) {
  const mod = button.match(/desk \? " ?([a-z][a-z0-9-]*)" : ""/)
  assert.ok(mod, "VaultButton.jsx still sets a desktop modifier on the capsule")
  const states = [...color.matchAll(/^\s{2}([a-z]+):\s*\{ color:/gm)].map(m => m[1])
  assert.ok(states.length >= 3, `connection states read from connection-color.js: ${states.join(", ")}`)
  assert.match(button, /class=\{`vault-status \$\{state\}/, "the capsule still carries .vault-status and its state")
  return ["vault-status", ...states, mod[1]]
}

/** Rules whose selector is one plain class, with the box-laying-out declarations they make. */
export function singleClassBoxRules(css, file = "") {
  const out = []
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "")
  for (const m of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const decls = m[2].split(";").map(d => d.trim()).filter(Boolean)
    for (const sel of m[1].split(",").map(s => s.trim())) {
      const one = sel.match(/^\.([A-Za-z][\w-]*)$/)
      if (!one) continue
      const box = decls.filter(d => /^(display|position|width|min-width|max-width|height|min-height|max-height|inset|top|right|bottom|left|grid|grid-template-[\w-]+|aspect-ratio)\s*:/.test(d))
      if (box.length) out.push({ cls: one[1], sel, box, file })
    }
  }
  return out
}

const cssFiles = readdirSync(join(SRC, "styles")).filter(f => f.endsWith(".css"))
const allRules = cssFiles.flatMap(f => singleClassBoxRules(read(join("styles", f)), f))

test("no class the Vault capsule carries also lays out another box", () => {
  assert.ok(allRules.length > 20, `scanned ${cssFiles.length} stylesheets, ${allRules.length} single-class box rules`)
  const carried = new Set(capsuleClasses())
  assert.ok(carried.has("desk") === false, "the desktop modifier is no longer the bare class `desk`")
  const clashes = allRules.filter(r => carried.has(r.cls)).map(r => `${r.file} .${r.cls} { ${r.box.join("; ")} }`)
  // .vault-status is the capsule's own rule: it is the one that may size it.
  assert.deepEqual(clashes.filter(c => !c.includes(".vault-status {")), [])
})

test("the capsule keeps its own box: 48px tall, fixed, and the desktop modifier only moves it", () => {
  const base = allRules.find(r => r.cls === "vault-status")
  assert.ok(base, "settings.css still has a .vault-status rule")
  assert.ok(base.box.includes("height:48px") || base.box.some(d => /^height\s*:\s*48px$/.test(d)), `height 48px: ${base.box.join("; ")}`)
  assert.ok(base.box.some(d => /^display\s*:\s*inline-flex$/.test(d)), "display: inline-flex")
  assert.ok(base.box.some(d => /^position\s*:\s*fixed$/.test(d)), "position: fixed")

  const mod = capsuleClasses().at(-1)
  const rule = singleClassBoxRules(read("styles/settings.css")).find(r => r.sel === `.vault-status.${mod}`)
  assert.ok(!rule, `the desktop modifier .vault-status.${mod} must not lay out a box, it only moves it`)
  const anywhere = allRules.find(r => r.cls === mod)
  assert.equal(anywhere, undefined, `no other rule names .${mod}`)
})

test("the scan can fail: the selector shape that broke it is caught", () => {
  const buggy = ".vault-status{display:inline-flex;height:48px;position:fixed}\n.desk{display:grid;grid-template-columns:minmax(0,1fr) var(--dock-w);height:100dvh}"
  const rules = singleClassBoxRules(buggy, "desktop.css")
  assert.deepEqual(rules.find(r => r.cls === "desk").box, ["display:grid", "grid-template-columns:minmax(0,1fr) var(--dock-w)", "height:100dvh"])
  const carried = new Set(["vault-status", "connected", "desk"])
  assert.deepEqual(rules.filter(r => carried.has(r.cls) && r.cls !== "vault-status").map(r => r.cls), ["desk"], "a bare `desk` modifier is flagged")
  // and the fixed shape is not
  assert.deepEqual(singleClassBoxRules(".vault-status{height:48px}\n.vault-status.desk-float{right:0;bottom:20px}").filter(r => r.cls !== "vault-status"), [])
})
