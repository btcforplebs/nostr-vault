// Every class a screen draws has its stylesheet loaded with it (N5, NV_POST_REVIEW_PLAN_2026_11_11 lane M12).
// Since the app was split into chunks (lazy-screens.js), a stylesheet arrives with the chunk that imports it, not with
// the app. Twice that left a screen drawing classes whose rules lived in another screen's sheet, and only Logen's
// screenshots caught it: #1882, the Vault tab's activity rows, styled by notifications.css, which only the
// Notifications chunk imported (fixed in 4db51c718 by importing it from VaultScreen too).
//
// The check is static, over the source, with no build: it walks the import graph from main.jsx the way the bundler
// splits it. Static imports stay in the importer's chunk; an `import("./x.jsx")` is a chunk of its own, drawn only once
// its importer is up, so it can rely on the importer's sheets plus its own. A class a module draws (a literal in a
// class or className attribute) must be defined in a sheet that is loaded wherever that module can be drawn. Classes no
// sheet defines are left alone (state hooks, test ids); a class two sheets define is fine if either is loaded.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

const root = fileURLToPath(new URL("..", import.meta.url))
const rel = f => path.relative(root, f)
const read = f => readFileSync(f, "utf8")

const resolveJs = (from, spec) => {
  const p = path.resolve(path.dirname(from), spec)
  return [p, `${p}.js`, `${p}.jsx`, path.join(p, "index.js")].find(c => existsSync(c) && /\.(m?js|jsx)$/.test(c))
}

// One module's edges. `css` covers both `import "x.css"` and the run-time `import("x.css")` the node tests can skip:
// the bundler puts either in the module's chunk.
const edgesMemo = new Map()
function edges(f) {
  if (edgesMemo.has(f)) return edgesMemo.get(f)
  const src = read(f).replace(/^\s*\/\/.*$/gm, "")
  const out = { js: new Set(), lazy: new Set(), css: new Set() }
  for (const m of src.matchAll(/^\s*(?:import|export)\s+(?:[^"'();]*?\s+from\s+)?["'](\.[^"']+)["']/gm)) {
    if (m[1].endsWith(".css")) out.css.add(path.resolve(path.dirname(f), m[1]))
    else { const r = resolveJs(f, m[1]); if (r) out.js.add(r) }
  }
  for (const m of src.matchAll(/\bimport\(\s*["'](\.[^"']+)["']\s*\)/g)) {
    if (m[1].endsWith(".css")) out.css.add(path.resolve(path.dirname(f), m[1]))
    else { const r = resolveJs(f, m[1]); if (r) out.lazy.add(r) }
  }
  edgesMemo.set(f, out)
  return out
}

// A sheet and the sheets it @imports.
const withImports = (css, out = new Set()) => {
  if (out.has(css) || !existsSync(css)) return out
  out.add(css)
  for (const m of read(css).matchAll(/@import\s+(?:url\()?["']([^"']+)["']/g)) withImports(path.resolve(path.dirname(css), m[1]), out)
  return out
}

/** One chunk from `entry`: its modules (static imports only), the sheets they load, and the chunks they import(). */
function chunk(entry) {
  const mods = new Set(), sheets = new Set(), lazy = new Set()
  const visit = f => {
    if (mods.has(f)) return
    mods.add(f)
    const e = edges(f)
    for (const c of e.css) withImports(c, sheets)
    for (const j of e.js) visit(j)
    for (const l of e.lazy) lazy.add(l)
  }
  visit(entry)
  return { mods, sheets, lazy }
}

/** class -> the sheets that define it, over every stylesheet in src. */
function definitions() {
  const defs = new Map()
  const walk = d => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (e.name.endsWith(".css")) {
        const src = read(p).replace(/\/\*[\s\S]*?\*\//g, "").replace(/url\([^)]*\)/g, "").replace(/"[^"]*"|'[^']*'/g, "")
        // Selectors only: the text before each `{`, so a value such as `1.5em` is never read as a class.
        for (const sel of src.matchAll(/([^{}]+)\{/g))
          for (const m of sel[1].matchAll(/\.(-?[A-Za-z_][\w-]*)/g)) {
            if (!defs.has(m[1])) defs.set(m[1], new Set())
            defs.get(m[1]).add(p)
          }
      }
    }
  }
  walk(path.join(root, "src"))
  return defs
}

/** The class names `f` draws: the string literals of its class / className attributes. */
function classesOf(f) {
  const src = read(f).replace(/^\s*\/\/.*$/gm, ""), out = new Set()
  const take = s => { for (const c of s.split(/\s+/)) if (/^-?[A-Za-z_][\w-]*$/.test(c)) out.add(c) }
  for (const m of src.matchAll(/\bclass(?:Name)?=(?:"([^"]*)"|'([^']*)'|\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\})/g)) {
    if (m[1] != null || m[2] != null) { take(m[1] ?? m[2]); continue }
    const expr = m[3]
    for (const s of expr.matchAll(/"([^"]*)"|'([^']*)'/g)) take(s[1] ?? s[2])
    for (const t of expr.matchAll(/`([^`]*)`/g)) take(t[1].replace(/\$\{[^}]*\}/g, " "))
  }
  return out
}

/**
 * Every place a module can be drawn, with the sheets loaded there, and the classes it draws that none of them define.
 * -> [{ file, cls, chunk, from }]
 */
function unstyled() {
  const defs = definitions(), gaps = [], done = new Set()
  const check = (entry, loaded, from) => {
    const c = chunk(entry)
    const have = new Set([...loaded, ...c.sheets])
    const key = `${entry}|${[...have].sort().join(",")}`
    if (done.has(key)) return
    done.add(key)
    for (const f of c.mods) {
      if (!f.endsWith(".jsx")) continue
      for (const cls of classesOf(f)) {
        const where = defs.get(cls)
        if (where && ![...where].some(s => have.has(s))) gaps.push({ file: rel(f), cls, chunk: rel(entry), from, sheets: [...where].map(rel) })
      }
    }
    for (const l of c.lazy) check(l, have, rel(entry))
  }
  check(path.join(root, "main.jsx"), new Set(), null)
  return gaps
}

test("the graph walk sees the split: Vault and Notifications are chunks of their own, each loading notifications.css", () => {
  const boot = chunk(path.join(root, "main.jsx"))
  const vault = path.join(root, "src/screens/VaultScreen.jsx"), notifs = path.join(root, "src/screens/NotificationsScreen.jsx")
  assert.ok(boot.mods.size > 50, `boot modules found (${boot.mods.size})`)
  assert.ok(!boot.mods.has(vault), "VaultScreen isn't in the boot chunk")
  assert.ok(boot.sheets.has(path.join(root, "src/styles/feeds.css")), "boot-sheets.js's sheets count as boot sheets")
  assert.ok(boot.sheets.has(path.join(root, "src/styles/tokens.css")), "app.css's @imports count")
  const lazy = new Set([...boot.mods].flatMap(f => [...edges(f).lazy]))
  assert.ok(lazy.has(vault) && lazy.has(notifs), "both are import()ed from lazy-screens.js")
  for (const s of [vault, notifs]) assert.ok(chunk(s).sheets.has(path.join(root, "src/styles/notifications.css")), `${rel(s)} loads notifications.css`)
})

test("class literals and selectors are read the way the screens write them", () => {
  const defs = definitions()
  assert.ok(defs.get("screen")?.size, ".screen is defined")
  assert.ok(!defs.has("5em") && !defs.has("css"), "no values or file names read as classes")
  const notifRow = [...classesOf(path.join(root, "src/screens/VaultScreen.jsx"))].filter(c => [...(defs.get(c) ?? [])].some(s => s.endsWith("notifications.css")))
  assert.ok(notifRow.length > 0, "the Vault screen draws notifications.css classes (the #1882 case)")
})

test("#1882 comes back if VaultScreen stops importing notifications.css (the check can fail)", () => {
  const vault = path.join(root, "src/screens/VaultScreen.jsx"), notifCss = path.join(root, "src/styles/notifications.css")
  const real = edges(vault)
  edgesMemo.set(vault, { ...real, css: new Set([...real.css].filter(c => c !== notifCss)) })
  try {
    const gaps = unstyled().filter(g => g.chunk === rel(vault))
    assert.ok(gaps.some(g => g.sheets.includes(rel(notifCss))), `missing notifications.css is caught: ${JSON.stringify(gaps.slice(0, 3))}`)
  } finally { edgesMemo.set(vault, real) }
})

// Drawn only on the desktop layout, whose shell (DesktopShell, a chunk of its own) imports desktop.css and is mounted
// whenever they are: main.jsx's `.relay-host` is only styled under `.desk-app` (on a phone it is a plain box on
// purpose), and ThumbOpen's `.condensed-open` is only drawn when thumbOpens() (a desktop width, the same test main.jsx
// uses to mount the shell). Exact file + class + sheet, so anything else desktop.css alone styles still fails.
const DESKTOP_ONLY = new Set(["main.jsx .relay-host", "src/desktop/ThumbOpen.jsx .condensed-open"])
const desktopOnly = g => DESKTOP_ONLY.has(`${g.file} .${g.cls}`) && g.sheets.length === 1 && g.sheets[0] === "src/styles/desktop.css"

test("every class a screen draws is styled by a sheet loaded with it", () => {
  const gaps = unstyled().filter(g => !desktopOnly(g))
  const say = gaps.map(g => `${g.file} draws .${g.cls} in chunk ${g.chunk}${g.from ? ` (opened from ${g.from})` : ""}; only ${g.sheets.join(", ")} define it`)
  assert.deepEqual(say, [], "import the sheet from the screen (or the component) that draws the class")
})
