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

// Safari's 7-day erase: named on iPhone, iPad and Mac Safari unless opened as a Home Screen or Dock app.
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
const IPHONE_CHROME = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/139.0 Mobile/15E148 Safari/604.1"
const IPAD = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
const MAC_CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
const MAC_FIREFOX = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0"
const ANDROID = "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36"
const { sevenDayErase } = await import("../src/components/StorageNote.jsx")

test("Safari's 7-day erase: every iPhone/iPad browser and Mac Safari, not other browsers or a Home Screen app", () => {
  assert.equal(sevenDayErase({ userAgent: IPHONE }, false), "ios")
  assert.equal(sevenDayErase({ userAgent: IPHONE_CHROME }, false), "ios", "Chrome on iPhone is WebKit too")
  assert.equal(sevenDayErase({ userAgent: IPAD, maxTouchPoints: 5 }, false), "ios", "iPadOS says Macintosh")
  assert.equal(sevenDayErase({ userAgent: IPAD, maxTouchPoints: 0 }, false), "mac")
  assert.equal(sevenDayErase({ userAgent: MAC_CHROME, maxTouchPoints: 0 }, false), "")
  assert.equal(sevenDayErase({ userAgent: MAC_FIREFOX, maxTouchPoints: 0 }, false), "")
  assert.equal(sevenDayErase({ userAgent: ANDROID }, false), "")
  assert.equal(sevenDayErase({ userAgent: IPHONE }, true), "", "opened from the Home Screen")
  assert.equal(sevenDayErase({ userAgent: IPHONE, standalone: true }, false), "", "iOS's own standalone flag")
  assert.equal(sevenDayErase(undefined, undefined), "")
})

test("the note says how to keep the copy on Safari, and nothing extra elsewhere", () => {
  const say = safari => { const flat = n => n == null || n === false ? "" : typeof n === "string" ? n : [n.props?.children].flat().map(flat).join(" "); return flat(StorageNote({ kept: false, safari })) }
  assert.match(say("ios"), /after 7 days without a visit.+Share › Add to Home Screen/)
  assert.match(say("mac"), /after 7 days without a visit.+File › Add to Dock/)
  assert.doesNotMatch(say(""), /7 days/)
})
