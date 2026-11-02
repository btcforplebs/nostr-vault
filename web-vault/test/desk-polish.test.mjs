// Desktop web polish from Logen's live shot (2026-11-02): the bar stays put, Live Vault's faces and pictures, Messages
// peek reads on its own, a compact row's photo opens full size.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { facesText } from "../src/desktop/space/live-vault.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")

test("the desktop page can't scroll under the window's edge: no phone tab-bar room, and clipped", () => {
  const css = src("styles/desktop.css")
  assert.match(css, /^\.app\.desk-app \{ padding-bottom: 0; \}/m, "two classes, so it beats app.css's .app, which loads later")
  assert.match(css, /^\.desk-app \{[^}]*overflow: clip;/m)
  assert.match(src("styles/app.css"), /^\.app \{ padding-bottom: calc\(/m, "the phone rule it has to beat is still there")
  assert.match(src("styles/space.css"), /\.sp-panels \{[^}]*overflow-y: auto;/, "a short window scrolls the panels, not the page")
})

test("Live Vault: every row's picture loads, and the faces say what they count", () => {
  const lv = src("desktop/space/LiveVault.jsx")
  assert.match(lv, /const trusted = \(\) => true/)
  assert.doesNotMatch(lv, /\+\{more\}/, "no bare +79")
  assert.equal(facesText(84, true), "84 people since you looked")
  assert.equal(facesText(1, false), "1 person lately")
  assert.equal(facesText(1200, false), "1,200 people lately")
})

test("Messages peek reads the messages itself, with the Messages screen's own loader", () => {
  const mp = src("desktop/space/MessagesPeek.jsx")
  assert.match(mp, /import \{ useMessages \} from "..\/..\/screens\/MessagesScreen.jsx"/)
  assert.match(mp, /const state = useMessages\(ctx\)/)
  assert.doesNotMatch(mp, /Open Messages once/)
})

test("a compact row's photo opens full size on a wide window, and the thread on a phone", () => {
  const cn = src("components/CondensedNote.jsx")
  assert.match(cn, /if \(!video && thumbOpens\(\)\) return <ThumbOpen media=\{media\} note=\{note\} more=\{more\} big=\{big\} \/>/)
  const to = src("desktop/ThumbOpen.jsx")
  assert.match(to, /deskModeFor\(innerWidth\) !== "phone"/)
  assert.match(to, /e\.stopPropagation\(\); setOpen\(true\)/)
  assert.match(to, /<MediaLightbox items=\{lightboxItems\(media, note\.tags\)\}/)
})
