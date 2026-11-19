// The DM field: Return sends on a desktop (as the Mac app does), Shift/Option + Return is a new line, a touch
// screen's Return is always a new line, and an input method's Return (picking a word) never sends.
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
const { sendsOnEnter } = await import("../src/screens/ConversationScreen.jsx")
const key = (k, o = {}) => ({ key: k, shiftKey: false, altKey: false, isComposing: false, keyCode: 13, ...o })

test("Return sends on a desktop", () => assert.equal(sendsOnEnter(key("Enter"), false), true))
test("Shift or Option + Return is a new line", () => {
  assert.equal(sendsOnEnter(key("Enter", { shiftKey: true }), false), false)
  assert.equal(sendsOnEnter(key("Enter", { altKey: true }), false), false)
})
test("on a touch screen Return is a new line; Send is the button", () => assert.equal(sendsOnEnter(key("Enter"), true), false))
test("an input method's Return picks a word, it doesn't send", () => {
  assert.equal(sendsOnEnter(key("Enter", { isComposing: true }), false), false)
  assert.equal(sendsOnEnter(key("Enter", { keyCode: 229 }), false), false)
})
test("other keys don't send", () => assert.equal(sendsOnEnter(key("a"), false), false))

test("New message looks up names only: a key, near-key or address never goes to the search relays", async () => {
  const { peopleQuery } = await import("../src/screens/MessagesScreen.jsx")
  for (const q of ["alice", "Bob Smith", "j"]) assert.equal(peopleQuery(q), true, q)
  for (const q of ["", "   ", "npub1abc", "NPUB1xyz", "nprofile1qqs", "nostr:npub1x", "deadbeef01", "a".repeat(64), "bob@example.com", "@alice"])
    assert.equal(peopleQuery(q), false, q)
})

// B8 (Messages UX check 2026-11-18): on a phone, the thread's composer sat under the on-screen keyboard (sticky counts
// from the layout viewport's bottom, which the keyboard covers). While a keyboard is up it's lifted by what it covers.
test("thread composer: lifted above a phone keyboard by what the keyboard covers, nothing without one", async () => {
  const { keyboardLift } = await import("../src/screens/ConversationScreen.jsx")
  const { keyboardFrame } = await import("../src/components/keyboard-frame.js")
  assert.equal(keyboardLift(null, 800), null)
  assert.equal(keyboardLift(keyboardFrame({ height: 800, scale: 1, offsetTop: 0 }, 800), 800), null, "no keyboard")
  assert.equal(keyboardLift(keyboardFrame({ height: 420, scale: 1, offsetTop: 0 }, 800), 800), 380)
  assert.equal(keyboardLift(keyboardFrame({ height: 420, scale: 1, offsetTop: 300 }, 800), 800), 80, "Safari scrolled the page to the caret")
  assert.equal(keyboardLift({ top: 500, height: 420 }, 800), 0)
  const src = readFileSync(new URL("../src/screens/ConversationScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /keyboardLift\(useKeyboardFrame\(coarse\(\)\)/, "only a touch screen's keyboard")
  const css = readFileSync(new URL("../src/styles/dms.css", import.meta.url), "utf8")
  assert.match(css, /\.dm-compose\.kb \{ bottom: calc\(var\(--kb-lift\) \+ 8px\); \}/)
})
