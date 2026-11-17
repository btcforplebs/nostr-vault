// The zap list fixes (Logen 11-16): the Reader napplet's tap zaps the default and a hold picks; the desktop's right-click
// on the bolt opens only the picker; a tap never sends under 1 sat; condensed reply lines carry no bolt.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents } from "../src/napplet/reader-intents.js"
import { DEFAULT_ZAP_SATS, loadWallet, walletState, zapDefault } from "../src/net/wallet.js"

const src = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")
const note = finalizeEvent({ kind: 1, created_at: 100, tags: [], content: "zap me" }, generateSecretKey())

test("quick zap floors at 1 sat: a saved 0, a fraction or junk sends the 1-sat default, never 0", async () => {
  assert.equal(DEFAULT_ZAP_SATS, 1)
  for (const v of [0, -5, 0.4, "0", "abc", null, undefined, NaN, Infinity]) assert.equal(zapDefault(v), 1, String(v))
  assert.equal(zapDefault(21.9), 21)
  assert.equal(zapDefault("1000"), 1000)
  assert.equal(zapDefault(50_000_000), 10_000_000)
  let rec = { defaultSats: 0 }
  await loadWallet("e".repeat(64), { get: async () => rec, put: async v => { rec = v } })
  assert.equal(walletState().defaultSats, 1, "an old record of 0 reads as 1")
  const button = src("src/components/ZapButton.jsx"), sheet = src("src/napplet/NoteSheets.jsx")
  assert.match(button, /const quick = zapDefault\(wallet\.defaultSats\)/)
  assert.match(button, /send\(quick\)/)
  assert.doesNotMatch(button, /send\(wallet\.defaultSats\)/)
  assert.match(sheet, /sats: zapDefault\(wallet\.defaultSats\)/)
})

test("Reader napplet: a tap asks the shell for a quick zap, a hold or right-click for the picker", async () => {
  const bus = createBus(), ran = []
  readerIntents({ bus, openCompose: async () => ({ send: () => {} }), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent,
    onZap: (n, quick) => ran.push([n.id, quick]) })
  const reader = { dTag: "nv-reader", send: () => {} }
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "zap", payload: { event: note, quick: true } })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "zap", payload: { event: note } })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "zap", payload: { event: note, quick: "yes" } })).ok, true)
  assert.deepEqual(ran, [[note.id, true], [note.id, false], [note.id, false]], "only a real true is a quick zap")

  const html = src("napplets/reader/index.html")
  assert.match(html, /b\.onclick = e => \{ e\.stopPropagation\(\); if \(held\) \{ held = false; return \} shellAct\("zap", ev, \{ quick: true \}\) \}/)
  assert.match(html, /timer = setTimeout\(\(\) => \{ held = true; shellAct\("zap", ev\) \}, 500\)/)
  assert.match(html, /b\.oncontextmenu = e => \{ e\.preventDefault\(\); e\.stopPropagation\(\); clearTimeout\(timer\); shellAct\("zap", ev\) \}/)
  const pane = src("src/napplet/ReaderPane.jsx")
  assert.match(pane, /onZap: \(n, quick\) => setSheet\(\{ kind: "zap", note: n, quick \}\)/)
  assert.match(pane, /<ZapSheet ctx=\{ctx\} note=\{sheet\.note\} quick=\{!!sheet\.quick\}/)
  // The quick sheet sends once the author's lightning address is known, then closes; it never opens the picker.
  const sheet = src("src/napplet/NoteSheets.jsx")
  assert.match(sheet, /if \(!quick \|\| fired\.current \|\| !ready\) return/)
  assert.match(sheet, /if \(quick\) return \(/)
})

test("desktop: a right-click on the bolt opens only its picker, never the note's menu as well", () => {
  const menu = src("src/desktop/ContextMenu.jsx"), button = src("src/components/ZapButton.jsx")
  assert.match(menu, /if \(target\.closest\("\.zap"\)\) return null/)
  assert.match(button, /onContextMenu=\{e => \{ e\.preventDefault\(\); e\.stopPropagation\(\); up\(\); if \(!busy\) setPicking\(true\) \}\}/)
  // The menu's own check comes before the note lookup, so your own post's Delete can't open over the bolt either.
  assert.ok(menu.indexOf('closest(".zap")') < menu.indexOf("[data-note-id]"))
})

test("condensed reply lines carry no bolt; full replies and the main post keep theirs", () => {
  const row = src("src/components/CondensedNote.jsx")
  assert.doesNotMatch(row, /ZapButton|condensed-zap/)
  assert.doesNotMatch(src("src/styles/feeds.css"), /\.condensed-zap/)
  assert.match(src("src/components/NoteCard.jsx"), /<ZapButton note=\{note\} \/>/)
})
