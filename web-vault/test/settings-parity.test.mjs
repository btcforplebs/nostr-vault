// Web Settings parity with the iPhone (Logen, 2026-11-05): Feed, Appearance, Media & Cache, Privacy and Notifications
// pages, the (i) help words, notification names, and Block Someone by npub.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { HELP, helpTopic } from "../src/net/settings-help.js"
import { popAt } from "../src/components/setting-info.js"
import { blockTarget } from "../src/screens/settings/block-someone.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")

test("every (i) on the web says word for word what the iPhone's says (SettingsHelp.swift)", () => {
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Models/SettingsHelp.swift", import.meta.url), "utf8")
  const names = Object.fromEntries([...swift.matchAll(/case (\w+) = "([\w.]+)"/g)].map(m => [m[2], m[1]]))
  const said = (part, name) => {
    const block = swift.slice(swift.indexOf(`var ${part}: String`))
    return block.match(new RegExp(`case \\.${name}: return "((?:[^"\\\\]|\\\\.)*)"`))?.[1]
  }
  for (const [key, [title, text]] of Object.entries(HELP)) {
    assert.ok(names[key], `${key} is an iPhone topic`)
    assert.equal(title, said("title", names[key]), `${key} title`)
    assert.equal(text, said("text", names[key]), `${key} text`)
  }
  assert.equal(helpTopic("nope"), null, "no words, no (i)")
})

test("the bubble sits under its button, inside the window", () => {
  assert.deepEqual(popAt({ left: 100, bottom: 50 }, 1440), { top: 56, left: 88, width: 280 })
  assert.equal(popAt({ left: 380, bottom: 50 }, 390).left, 102, "kept 8px inside a phone's right edge")
  assert.equal(popAt({ left: 2, bottom: 50 }, 390).left, 8)
})

test("Block Someone takes an npub, nprofile or hex key, never your own", () => {
  const me = getPublicKey(generateSecretKey()), them = getPublicKey(generateSecretKey())
  assert.equal(blockTarget(npubEncode(them), me), them)
  assert.equal(blockTarget(`  ${them}  `, me), them)
  assert.equal(blockTarget(npubEncode(me), me), null)
  assert.equal(blockTarget("npub1nope", me), null)
  assert.equal(blockTarget("", me), null)
  assert.match(src("screens/SettingsScreen.jsx"), /page === "blocked" && <><BlockSomeone ctx=\{ctx\} \/><Blocked ctx=\{ctx\} \/><\/>/)
  assert.match(src("screens/settings/BlockSomeone.jsx"), /<BlockDialog ctx=\{ctx\} pubkey=\{target\}/, "the same confirmation as Block on a note")
})

test("the index lists pages, as the iPhone; its old inline sections moved to them", () => {
  const screen = src("screens/SettingsScreen.jsx")
  for (const gone of ["NotifySwitch", "LineLimitSteppers", "SendDelayPicker", "AutoplaySwitch", "PostButtonsSwitch", "DefaultReactionRow", "NostrVaultLogoSwitch"])
    assert.doesNotMatch(screen, new RegExp(`<${gone} `), gone)
  for (const [page, comp] of [["feed", "FeedSettingsPage"], ["appearance", "AppearancePage"], ["media", "MediaCachePage"], ["privacy", "PrivacyPage"], ["notifications", "NotificationsPage"]])
    assert.match(screen, new RegExp(`page === "${page}" && <${comp} />`))
  assert.match(screen, /const ORDER = \["Account", "Feed & Display", "Notifications", "Relays"/)
})

test("Privacy shows the iPhone's two lookups, off, and says the web doesn't make them", () => {
  const p = src("screens/settings/PrivacyPage.jsx")
  assert.match(p, /<Row title="Follower Counts from Vertex" info="privacy.vertex" \/>/)
  assert.match(p, /<Row title="Check Fanfares Articles" info="privacy.fanfares" \/>/)
  assert.match(p, /checked=\{false\} disabled/, "no switch that would do nothing")
  assert.match(p, /doesn't make either lookup yet/)
})

test("Media & Cache doesn't offer cache switches the web can't honour", () => {
  const p = src("screens/settings/MediaCachePage.jsx").split("\n").filter(l => !l.startsWith("//")).join("\n")
  assert.doesNotMatch(p, /Disable Media Cache|Keep Media For|Clear Media Cache/)
  assert.match(p, /your browser caches them/)
})

test("help buttons sit on the rows that have iPhone words", () => {
  for (const [file, topic] of [["components/AutoplaySwitch.jsx", "media.autoplay"], ["components/SendDelayPicker.jsx", "post.sendDelay"],
    ["components/NotifySwitch.jsx", "notify.enable"], ["components/NotifySwitch.jsx", "notify.perAccount"], ["screens/settings/FeedSettingsPage.jsx", "feed.relays"],
    ["screens/settings/BlockSomeone.jsx", "account.blocked"]])
    assert.match(src(file), new RegExp(`<SettingInfo topic="${topic.replace(".", "\\.")}" />`), `${file} ${topic}`)
  assert.match(src("components/LineLimitSteppers.jsx"), /display\.compactLines.*display\.threadedLines/)
})
