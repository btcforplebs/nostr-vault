// Nuclear unfollow + Private block, the web screens (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md): the profile ··· menu's two
// entries, the globe lighting who'd be cut, and the panel's order: list all checked, one warning always, a second from
// 25, "Backup saved ✓" only once the backup is in, Undo. The publish rules are test/nuclear-unfollow.test.mjs.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const read = p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")

test("profile ··· menu: Nuclear unfollow opens the globe's nuke mode; Private block is private only", () => {
  const src = read("components/Moderation.jsx")
  assert.match(src, /\{!note && !ctx\.signer\?\.readOnly && <button role="menuitem" class="danger" onClick=\{\(\) => \{ setOpen\(false\); location\.hash = `#\/wot\/\$\{who\}\/nuke` \}\}>Nuclear unfollow…<\/button>\}/)
  assert.match(src, /\{!note && !isBlocked && <button role="menuitem" class="danger" onClick=\{pick\("private-block"\)\}>Private block…<\/button>\}/)
  assert.match(src, /dialog === "private-block" && <BlockDialog ctx=\{ctx\} pubkey=\{who\} name=\{name\} privateOnly /)
  // Private only: always isPrivate, no box to untick, and no Block button when the signer can't encrypt.
  assert.match(src, /setBlock\(ctx, pubkey, \{ block: true, isPrivate: privateOnly \|\| priv \}\)/)
  const only = src.slice(src.indexOf("if (privateOnly) return ("), src.indexOf("  return (\n    <Dialog label={`Block ${name}`}"))
  assert.doesNotMatch(only, /type="checkbox"/)
  assert.match(only, /\{canPrivate && <button type="button" class="danger-fill"[^\n]*>\{busy \? waiting\(ctx\) \?\? "Blocking…" : "Block privately"\}<\/button>\}/)
})

test("globe: in nuke mode your follows who follow X (and X) are lit, no card opens, My Web steps aside", () => {
  const src = read("screens/WotScreen.jsx")
  assert.match(src, /const nuking = !!pubkey && pubkey !== me && location\.hash\.startsWith\(`#\/wot\/\$\{pubkey\}\/nuke`\)/)
  assert.match(src, /const cut = useMemo\(\(\) => \(nuking && lists \? followersOfAmong\(pubkey, follows, lists, me\) : null\)/)
  assert.match(src, /if \(cut\) return new Set\(\[\.\.\.cut, pubkey\]\)/)
  assert.match(src, /if \(pubkey && pubkey !== me && !nuking\) \{ setPicked\(pubkey\)/)
  assert.match(src, /\{nuking && <NuclearPanel key=\{pubkey\} ctx=\{ctx\} target=\{pubkey\} cut=\{cut\} missing=\{missing\} \/>\}/)
  assert.match(src, /!listOpen && !nuking && \(/)
})

test("panel: everyone checked to start (X first when followed), one warning always, the second from 25, backup before publish", () => {
  const src = read("screens/WotNuclear.jsx")
  assert.match(src, /const everyone = cut \? \[\.\.\.\(followsTarget \? \[target\] : \[\]\), \.\.\.cut\] : null/)
  assert.match(src, /if \(everyone && !checked\) setChecked\(new Set\(everyone\)\)/)
  // Unfollow N -> warn1 always; warn1's button -> warn2 when warningsFor says 2, else the run.
  assert.match(src, /onClick=\{\(\) => setStep\("warn1"\)\}>Unfollow \{people\(n\)\}<\/button>/)
  assert.match(src, /const confirmFirst = \(\) => \(warningsFor\(n\) === 2 \? setStep\("warn2"\) : run\(\)\)/)
  assert.match(src, /onClick=\{confirmFirst\}>Unfollow \{people\(n\)\}/)
  assert.match(src, /onClick=\{run\}>Yes, unfollow \{people\(n\)\}/)
  assert.equal((src.match(/onClick=\{run\}/g) ?? []).length, 1, "only the second warning runs it directly")
  // "Backup saved ✓" is shown from nuclearUnfollow's onBackup, which comes before anything is signed.
  // Who goes is who's on the list NOW and ticked (pickedOf), never the ticks kept from when it was first drawn (Tron #2284).
  assert.match(src, /const picked = pickedOf\(everyone, checked\)\n  const n = picked\.length/)
  assert.match(src, /await unfollow\(\{ ctx, target, remove: new Set\(picked\), onBackup: \(\) => setBackedUp\(true\) \}\)/)
  assert.doesNotMatch(src, /remove: checked/)
  assert.match(src, /\{backedUp \? "Backup saved ✓" :/)
  assert.match(src, /undoNuclear\(\{ ctx, base: result\.base, event: result\.event \}\)/)
  assert.doesNotMatch(src, /setBlock|setMute|muteList|kind: 10000/, "no mute step")
  // The first warning's <dialog> closes as it unmounts (Dialog's cleanup), which fires onClose: it must not undo the
  // step that replaced it (that sent the second warning back to the list, found in a headless run).
  assert.match(src, /const backFrom = which => \(\) => setStep\(s => \(s === which \? "list" : s\)\)/)
  assert.match(src, /onClose=\{backFrom\("warn1"\)\}/)
  assert.match(src, /onClose=\{backFrom\("warn2"\)\}/)
  assert.doesNotMatch(src, /<Dialog [^>]*onClose=\{\(\) => setStep\("list"\)\}/)
})

test("desktop: #/wot/<X>/nuke stays the WoT napplet; the shell lights who'd go and puts its own panel over it", async () => {
  const desk = read("desktop/DesktopShell.jsx"), pane = read("napplet/WotPane.jsx")
  // Plan step 11 is held back for this deploy (e930b386 reverted): napplets on, the WoT napplet; off, WotScreen (its own nuke).
  assert.match(desk, /\{nappletsOn\(\) \? <WotPane ctx=\{ctx\} nuke=/)
  assert.match(desk, /: <WotScreen ctx=\{ctx\} pubkey=/)
  assert.match(desk, /<WotPane ctx=\{ctx\} nuke=\{\/\^#\\\/wot\\\/\[0-9a-f\]\{64\}\\\/nuke\/\.test\(location\.hash\) \? view\.arg : null\} open=\{\/\^#\\\/wot\\\/\[0-9a-f\]\{64\}\\\/\(web\|nuke\)\/\.test\(location\.hash\) \? null :/)
  assert.match(pane, /const cut = useMemo\(\(\) => \(nukeTarget && lists \? followersOfAmong\(nukeTarget, follows, lists, me\) : null\)/)
  assert.match(pane, /\.\.\.\(cut && !scene\.waiting \? \{ lit: \[\.\.\.cut, nukeTarget\] \} : \{\}\)/)
  assert.match(pane, /\{nukeTarget && <NuclearPanel key=\{nukeTarget\} ctx=\{ctx\} target=\{nukeTarget\} cut=\{cut\}/)
  assert.doesNotMatch(pane, /nuclearUnfollow\(/, "the publish is the panel's (shell), never the napplet's")
  // The napplet draws the shell's lit set when one comes, over Follow you back.
  const fs = await import("node:fs"), vm = await import("node:vm")
  const html = fs.readFileSync(new URL("../napplets/wot/index.html", import.meta.url), "utf8")
  const box = {}
  vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { webOf, litOf })`, { box, Map, Set })
  const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)
  const plain = box.webOf({ me: A, follows: [B, C], followsMe: [C] })
  assert.equal(box.litOf(plain, false), null)
  assert.deepEqual([...box.litOf(plain, true)], [C])
  const nuked = box.webOf({ me: A, follows: [B, C], followsMe: [C], lit: [B] })
  assert.deepEqual([...box.litOf(nuked, false)], [B])
  assert.deepEqual([...box.litOf(nuked, true)], [B])
})
