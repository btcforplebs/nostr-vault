// Clean mode (net/clean-mode.js, step W3): the built-in list masks words as first letter plus asterisks, only where
// text is drawn, only when the setting is on (off by default), whole words only.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { setCleanWords, cleanWordCount, maskWords, clean, cleanMode, setCleanMode } from "../src/net/clean-mode.js"
import { lastPreview } from "../src/net/dms.js"
import { showNotice } from "../src/net/notify-show.js"

const LIST = readFileSync(new URL("../src/net/clean-words-en.txt", import.meta.url), "utf8")
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

test("the web copy of the list is docs/clean-words/en.txt, byte for byte", () => {
  assert.equal(LIST, readFileSync(new URL("../../docs/clean-words/en.txt", import.meta.url), "utf8"))
})

test("masking: first letter kept with its case, same length, whole words only", () => {
  const list = new Set(["fuck", "shit", "ass"])
  assert.equal(maskWords("Fuck this SHIT", list), "F*** this S***")
  assert.equal(maskWords("what the fuck?! fuck.", list), "what the f***?! f***.")
  assert.equal(maskWords("class assume Scunthorpe bass ass", list), "class assume Scunthorpe bass a**")
  assert.equal(maskWords("fuck's sake", list), "f***'s sake")
  assert.equal(maskWords("fuck2 2fuck", list), "fuck2 2fuck", "a digit makes it a longer word")
  assert.equal(maskWords("", list), "")
})

test("off by default; on only on this device; clean() passes text through when off", () => {
  globalThis.localStorage = store()
  setCleanWords(LIST)
  assert.ok(cleanWordCount() > 100)
  assert.equal(cleanMode(), false)
  assert.equal(clean("oh fuck"), "oh fuck")
  assert.equal(setCleanMode(true), true)
  assert.equal(clean("oh FUCKING hell, motherfucker"), "oh F****** hell, m***********")
  assert.equal(clean(42), 42)
  assert.equal(setCleanMode(false), false)
  assert.equal(clean("oh fuck"), "oh fuck")
})

test("a message row's line is masked before it is cut, and a notification's title and body when shown", async () => {
  globalThis.localStorage = store()
  setCleanWords(LIST)
  setCleanMode(true)
  assert.equal(lastPreview("bullshit"), "b*******")
  const long = "x".repeat(57) + " fucking"
  assert.equal(lastPreview(long), "x".repeat(57) + " f*…", "the cut never leaves part of the word showing")
  const shown = []
  function N(title, opts) { shown.push([title, opts.body]); return { close() {} } }
  await showNotice({ title: "Shithead", body: "you ass", tag: "t", href: "#/" }, { sw: null, N })
  assert.deepEqual(shown, [["S*******", "you a**"]])
  setCleanMode(false)
  shown.length = 0
  await showNotice({ title: "Shithead", body: "you ass", tag: "t", href: "#/" }, { sw: null, N })
  assert.deepEqual(shown, [["Shithead", "you ass"]])
  delete globalThis.localStorage
})
