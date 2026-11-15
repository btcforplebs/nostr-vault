// One plan step 10a: Settings' list and plain preference pages as a napplet. The shell hands words, rows and values;
// a row opens only by a real id, a change only to a real setting with a real value.
import test from "node:test"
import assert from "node:assert/strict"
import { settingsAnswer, settingsHandlers, settingsHref, drawsHere, PAGES_HERE } from "../src/napplet/settings-answer.js"
import { createBus } from "../src/napplet/bus.js"

const W = { feedRelaysNote: "reads Read", feedNote: "new posts", autoplayNote: on => (on ? "plays" : "waits"), cacheNote: "browser caches", privacy: { sections: [{ label: "Profiles", note: "n", title: "Follower Counts from Vertex", info: "privacy.vertex" }], note: "web note" },
  notifyNote: "tab asks", storageLine: "copy", version: "3.2.2", commit: "abc1234", hasCommitLink: true }
const X = (o = {}) => ({ keyPage: false, box: false, events: 3, kept: true, sendDelay: 5, autoplay: true, notify: { on: false, why: "" }, types: { replies: true }, copied: false, ...o })

test("the list: groups in the phone's order, icons and colours only, the key row only with a key here", () => {
  const d = settingsAnswer("", X(), W)
  assert.deepEqual(d.groups.map(g => g.title), ["Account", "Feed & Display", "Notifications", "Relays", "Your Vault", "Advanced"])
  assert.equal(d.key, null); assert.equal(settingsAnswer("", X({ keyPage: true }), W).key.id, "key")
  assert.deepEqual(d.status, { events: 3, kept: true, line: "copy" })
  assert.equal(settingsAnswer("", X({ box: true }), W).status, null)
  assert.doesNotMatch(JSON.stringify(d), /#\/|https?:/, "no addresses cross")
  assert.ok(d.groups.flatMap(g => g.rows).every(r => /^(#[0-9a-f]{6}|var\(--accent\))$/i.test(r.color)))
})

test("pages: feed's send delay, media's autoplay, privacy off, notifications' alerts only when on", () => {
  const f = settingsAnswer("feed", X({ sendDelay: 10 }), W)
  assert.deepEqual(f.sendDelay.choices.map(c => c.label), ["Off", "5s", "10s"]); assert.equal(f.sendDelay.seconds, 10)
  assert.equal(settingsAnswer("media", X({ autoplay: false }), W).autoplay.note, "waits")
  assert.equal(settingsAnswer("privacy", X(), W).sections[0].title, "Follower Counts from Vertex")
  assert.deepEqual(settingsAnswer("notifications", X(), W).types, [])
  const on = settingsAnswer("notifications", X({ notify: { on: true, why: "" } }), W)
  assert.ok(on.types.length > 0 && on.types.every(t => typeof t.on === "boolean"))
  assert.equal(settingsAnswer("notifications", X({ notify: { on: false, why: "blocked" } }), W).note, "blocked")
  assert.equal(settingsAnswer("relays", X(), W).page, "", "a page it doesn't draw is the list")
  assert.ok(drawsHere("") && drawsHere(undefined) && PAGES_HERE.every(drawsHere) && !drawsHere("relays") && !drawsHere("key") && !drawsHere("blocked"))
})

test("go: a real row, the key page only with a key, This Box only in box mode", () => {
  assert.equal(settingsHref("relays"), "#/settings/relays"); assert.equal(settingsHref("accounts"), "#/accounts")
  assert.equal(settingsHref("key"), ""); assert.equal(settingsHref("key", { keyPage: true }), "#/settings/key")
  assert.equal(settingsHref("box"), ""); assert.equal(settingsHref("box", { box: true }), "#/box")
  assert.equal(settingsHref("#/settings/key"), ""); assert.equal(settingsHref("__proto__"), "")
})

test("handlers: state, go, set and copy, refusing what isn't a setting", async () => {
  const calls = []
  const ctl = new Proxy({}, { get: (_, k) => (...a) => calls.push([k, ...a]) })
  const bus = createBus(), me = { dTag: "nv-settings", send: () => {} }
  for (const h of settingsHandlers({ answer: () => ({ page: "" }), ctl, keyPage: () => false, box: () => false })) bus.register({ id: "shell:nv-settings", title: "NV", conventions: [], ...h })
  const ask = (action, payload = {}) => bus.invoke(me, { archetype: "settings", action, payload })
  assert.deepEqual((await ask("state")).data, { page: "" })
  const results = []
  for (const [a, p] of [["go", { to: "relays" }], ["go", { to: "key" }], ["go", { to: "learn" }], ["go", { to: "docs" }], ["go", { to: "javascript:alert(1)" }],
    ["set", { key: "sendDelay", value: 10 }], ["set", { key: "sendDelay", value: 7 }], ["set", { key: "autoplay", value: "yes" }], ["set", { key: "notify", value: true }],
    ["set", { key: "alert", value: { id: "replies", on: false } }], ["set", { key: "alert", value: { id: "nope", on: true } }], ["set", { key: "relays", value: [] }],
    ["copy", { what: "support" }], ["copy", { what: "nsec" }]]) results.push((await ask(a, p)).ok)
  assert.deepEqual(results, [true, false, true, true, false, true, false, false, true, true, false, false, true, false])
  assert.deepEqual(calls.map(c => c[0]), ["go", "learn", "open", "set", "set", "set", "copy"])
  assert.deepEqual(calls[3], ["set", "sendDelay", 10]); assert.deepEqual(calls[5], ["set", "alert", { id: "replies", on: false }])
})
