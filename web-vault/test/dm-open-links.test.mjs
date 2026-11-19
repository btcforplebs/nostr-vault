// B9 + B10 (Messages UX check 2026-11-18): a link's ?text= (Message seller) reaches the desktop napplet, clicking a chat
// that's already open opens it again, and the phone thread's Back on a cold #/dm/ link stays on the site.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { deskRedirect, phoneRedirect, parseHash } from "../src/desktop/routes.js"
import { dmLinkOf, openPayload } from "../src/napplet/dm-open.js"

const PK = "a".repeat(64)
const TEXT = "Hi! I'm interested in “Bike”.\nhttps://plebeian.market/x"
const link = `#/dm/${PK}?text=${encodeURIComponent(TEXT)}`

test("desktop: a #/dm/ link keeps its ?text= on the way to Messages, and back to the phone", () => {
  const desk = deskRedirect(link, "#/feed")
  assert.equal(parseHash(desk).route, "messages")
  assert.equal(parseHash(desk).params.get("dm"), PK)
  assert.equal(parseHash(desk).params.get("text"), TEXT)
  assert.equal(deskRedirect(`#/dm/${PK}`, "#/feed"), `#/messages?dm=${PK}`, "no text: as before")
  assert.equal(phoneRedirect(desk), link)
  assert.equal(phoneRedirect(`#/messages?dm=${PK}`), `#/dm/${PK}`)
})

test("napplet open: the text goes with the pubkey once, then comes off the address", () => {
  const replaced = []
  const win = { location: { hash: deskRedirect(link, "#/feed") }, history: { state: { nvDepth: 1 }, replaceState: (s, _, h) => replaced.push([s, h]) } }
  assert.deepEqual(openPayload(PK, win), { pubkey: PK, text: TEXT })
  assert.deepEqual(replaced, [[{ nvDepth: 1 }, `#/messages?dm=${PK}`]])
  assert.deepEqual(openPayload(PK, { location: { hash: `#/messages?dm=${PK}` }, history: { replaceState: () => assert.fail("nothing to take off") } }), { pubkey: PK })
})

test("a chat link is recognised from the hashchange's newURL, whatever is after it", () => {
  assert.equal(dmLinkOf(`https://nostrvault.app/${link}`), PK)
  assert.equal(dmLinkOf(`https://nostrvault.app/#/dm/${PK}`), PK)
  assert.equal(dmLinkOf(`https://nostrvault.app/#/messages?dm=${PK}`), null)
  assert.equal(dmLinkOf(`#/dm/${PK}x`), null)
  assert.equal(dmLinkOf(undefined), null)
  const pane = readFileSync(new URL("../src/napplet/MessagesPane.jsx", import.meta.url), "utf8")
  assert.match(pane, /addEventListener\("hashchange", f\)/)
  assert.match(pane, /const pk = dmLinkOf\(e\?\.newURL\), l = live\.current\n\s+if \(!pk \|\| !l\) return\n\s+sent\.current = pk/, "the [open] effect doesn't open it a second time (it would clear the text)")
  const html = readFileSync(new URL("../napplets/messages/index.html", import.meta.url), "utf8")
  assert.match(html, /openThread\(pk\) \/\/ clears the box at once[^\n]*\n\s+const t = d\.payload\.text\n\s+if \(typeof t === "string" && t\) \{ \$\("text"\)\.value = t\.slice\(0, 20000\)/)
  assert.doesNotMatch(html, /\$\("send"\)\.click\(\)|sendNow\(\)[^\n]*payload/, "typed in, never sent")
})

test("phone thread: Back goes back in the app, or to Messages on a cold link", async () => {
  const src = readFileSync(new URL("../src/screens/ConversationScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /onClick=\{\(\) => backToMessages\(\)\}>Back</)
  assert.doesNotMatch(src, /onClick=\{\(\) => history\.back\(\)\}>Back/)
  const { canGoBack } = await import("../src/components/nav-depth.js")
  const backToMessages = new Function("canGoBack", `return ${/export const backToMessages = ([^\n]+)/.exec(src)[1]}`)(canGoBack)
  let backs = 0
  const warm = { history: { state: { nvDepth: 2 }, back: () => backs++ }, location: { hash: `#/dm/${PK}` } }
  backToMessages(warm); assert.equal(backs, 1)
  const cold = { history: { state: null, back: () => backs++ }, location: { hash: `#/dm/${PK}` } }
  backToMessages(cold); assert.equal(backs, 1); assert.equal(cold.location.hash, "#/messages")
})
