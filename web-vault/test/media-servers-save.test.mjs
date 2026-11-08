// Settings › Media Servers Save (iPhone/Mac #1854, Android #1855): edits stay on screen, Save publishes the kind
// 10063 once, and leaving with unsaved changes asks Save / Discard / Keep Editing.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { guardLeave, watchLeaving } from "../src/net/leave-guard.js"
import { startNavDepth } from "../src/components/nav-depth.js"
import { changeCount, changesLabel, saveLabel, leaveQuestion } from "../src/net/media-servers-draft.js"

/** A window with a hash router and a history stack. Setting location.href pushes an entry and fires hashchange at its
 *  listeners in the order they were added, as Chrome does on window: the guard's (added as its module loads), then
 *  the real nav-depth.js (main.jsx's top level), then the app's router (App, once it mounts). */
function fakeWindow(href) {
  const win = new EventTarget()
  const routed = []
  const stack = [{ url: href, state: null }]
  let i = 0
  const fire = () => win.dispatchEvent(new Event("hashchange"))
  win.location = {
    get href() { return stack[i].url },
    set href(to) { stack.splice(i + 1); stack.push({ url: to, state: null }); i++; fire() },
  }
  win.history = {
    get state() { return stack[i].state },
    get length() { return stack.length },
    replaceState(state, _t, to = stack[i].url) { stack[i] = { url: to, state } },
    go(n) { i += n; fire() },
    back() { this.go(-1) },
  }
  win.setTimeout = setTimeout
  watchLeaving(win)
  startNavDepth(win)
  win.addEventListener("hashchange", () => routed.push(win.location.href))
  return { win, routed, stack: () => stack.map(e => e.url) }
}
const tick = () => new Promise(r => setTimeout(r, 0))
const PAGE = "https://x/#/settings/media-servers", SETTINGS = "https://x/#/settings"

/** Opened Settings, then Media Servers from it, then the page's guard. */
async function onPage(isDirty) {
  const w = fakeWindow(SETTINGS)
  w.win.location.href = PAGE
  await tick()
  const asked = []
  const g = guardLeave(w.win, { isDirty, ask: to => asked.push(to) })
  return { ...w, g, asked }
}

test("changes count adds and removes, an order change counts once, and the labels match the phone", () => {
  assert.equal(changeCount(["a", "b"], ["a", "b"]), 0)
  assert.equal(changeCount(["a", "c"], ["a", "b"]), 2)
  assert.equal(changeCount(["a", "b", "c"], ["a", "b"]), 1)
  assert.equal(changeCount(["b", "a"], ["a", "b"]), 1)
  assert.equal(changesLabel(1), "1 change")
  assert.equal(changesLabel(3), "3 changes")
  assert.equal(saveLabel(0), "Save")
  assert.equal(saveLabel(2), "Save (2 changes)")
  assert.equal(leaveQuestion(1), "Save 1 change?")
})

test("with no unsaved changes, leaving goes straight through", async () => {
  const { win, routed, asked, g } = await onPage(() => false)
  win.location.href = SETTINGS
  assert.equal(routed.at(-1), SETTINGS)
  assert.deepEqual(asked, [])
  g.stop()
})

test("with unsaved changes, a link asks, the page stays, and no copy of it is left for Back to land on", async () => {
  const { win, routed, asked, g, stack } = await onPage(() => true)
  const seen = routed.length
  win.location.href = "https://x/#/feed"
  // The router never saw the feed: history went back to the page's entry, and that passes.
  assert.deepEqual(routed.slice(seen), [PAGE])
  assert.deepEqual(asked, ["https://x/#/feed"])
  assert.equal(win.location.href, PAGE)
  await tick()
  // Back from here is Back off the page (asks again), and the page stays where it was in history.
  win.history.back()
  assert.deepEqual(asked, ["https://x/#/feed", SETTINGS])
  assert.equal(win.location.href, PAGE)
  assert.deepEqual(stack().slice(0, 2), [SETTINGS, PAGE])
  // Discard (or a Save that worked): go where the tap wanted, without asking again.
  g.leave(SETTINGS)
  assert.equal(routed.at(-1), SETTINGS)
  assert.equal(asked.length, 2)
  g.stop()
})

test("leave() lets one change through, not every one after it; stop() ends the asking", async () => {
  let dirty = true
  const { win, asked, g } = await onPage(() => dirty)
  g.leave("https://x/#/feed")
  await tick()
  win.location.href = "https://x/#/vault"
  assert.deepEqual(asked, ["https://x/#/vault"])
  g.stop()
  win.location.href = "https://x/#/profile"
  assert.equal(asked.length, 1)
  dirty = false
})

test("closing or reloading the tab with unsaved changes gets the browser's prompt", () => {
  const { win } = fakeWindow(PAGE)
  let dirty = false
  const g = guardLeave(win, { isDirty: () => dirty, ask: () => {} })
  const unload = () => { const e = new Event("beforeunload", { cancelable: true }); win.dispatchEvent(e); return e.defaultPrevented }
  assert.equal(unload(), false)
  dirty = true
  assert.equal(unload(), true)
  g.stop()
  assert.equal(unload(), false)
})

test("the page: one Save button, nothing published before it, and the leave dialog's three answers", () => {
  const src = readFileSync(new URL("../src/screens/MediaServersPage.jsx", import.meta.url), "utf8")
  // publishList is called only from save().
  assert.equal(src.match(/publishList\(/g).length, 1)
  assert.match(src, /const save = async \(\) => \{\n\s+setBusy\(true\); setErr\(""\); setStatus\(""\)\n\s+try \{\n\s+const \{ event, relays \} = await publishList\(/)
  assert.match(src, /saveLabel\(changes\)/)
  assert.match(src, /\{ONLY_SAVE\}/)
  assert.match(src, /guardLeave\(globalThis, \{ isDirty: \(\) => dirtyNow\.current, ask: setLeaving \}\)/)
  for (const answer of [">Save</button>", ">Discard</button>", ">Keep Editing</button>"]) assert.ok(src.includes(answer), answer)
  // Save from the dialog leaves only once the publish worked.
  assert.match(src, /if \(await save\(\)\) guard\.current\.leave\(to\)/)
})
