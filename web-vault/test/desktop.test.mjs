// The desktop layout's routing and shortcuts (src/desktop/routes.js, keys.js).
import test from "node:test"
import assert from "node:assert/strict"
import { deskModeFor, parseHash, withParam, deskRedirect, phoneRedirect, sideOf } from "../src/desktop/routes.js"
import { keyCommand } from "../src/desktop/keys.js"

const A = "a".repeat(64), B = "b".repeat(64)

test("window widths pick the layout at 760, 1024 and 1280", () => {
  assert.equal(deskModeFor(759), "phone")
  assert.equal(deskModeFor(760), "single")
  assert.equal(deskModeFor(1023), "single")
  assert.equal(deskModeFor(1024), "rail")
  assert.equal(deskModeFor(1279), "rail")
  assert.equal(deskModeFor(1280), "full")
})

test("parseHash splits route, arg and query", () => {
  const p = parseHash(`#/vault/notes?note=${A}`)
  assert.equal(p.route, "vault"); assert.equal(p.arg, "notes"); assert.equal(p.params.get("note"), A)
  assert.equal(parseHash("").route, "")
})

test("withParam sets and removes one key, keeping the rest", () => {
  assert.equal(withParam("#/feed", "note", A), `#/feed?note=${A}`)
  assert.equal(withParam(`#/search?q=x&note=${A}`, "note", B), `#/search?q=x&note=${B}`)
  assert.equal(withParam(`#/search?q=x&note=${A}`, "note", null), "#/search?q=x")
  assert.equal(withParam(`#/feed?note=${A}`, "note", null), "#/feed")
})

test("a thread link opens beside the list screen the user was on", () => {
  assert.equal(deskRedirect(`#/thread/${A}`, "#/vault"), `#/vault?note=${A}`)
  assert.equal(deskRedirect(`#/thread/${B}`, `#/profile/${A}?note=${A}`), `#/profile/${A}?note=${B}`)
})

test("a cold thread link, or one from WoT, opens beside the Feed", () => {
  assert.equal(deskRedirect(`#/thread/${A}`, null), `#/feed?note=${A}`)
  assert.equal(deskRedirect(`#/thread/${A}`, "#/wot"), `#/feed?note=${A}`)
})

test("a conversation link opens beside Messages; anything else is kept", () => {
  assert.equal(deskRedirect(`#/dm/${A}`, "#/feed"), `#/messages?dm=${A}`)
  assert.equal(deskRedirect("#/thread/nothex", "#/feed"), null)
  assert.equal(deskRedirect("#/feed", null), null)
  assert.equal(deskRedirect(`#/feed?note=${A}`, null), null)
})

test("on a phone, a desktop address goes back to the phone's thread and conversation screens", () => {
  assert.equal(phoneRedirect(`#/vault?note=${A}`), `#/thread/${A}`)
  assert.equal(phoneRedirect(`#/messages?dm=${A}`), `#/dm/${A}`)
  assert.equal(phoneRedirect("#/feed"), null)
  assert.equal(phoneRedirect("#/feed?note=zz"), null)
})

test("round trip: desktop then phone lands on the same thread", () => {
  assert.equal(phoneRedirect(deskRedirect(`#/thread/${A}`, "#/search")), `#/thread/${A}`)
})

test("sidebar rows light for their screens", () => {
  assert.equal(sideOf("feed"), "feed")
  assert.equal(sideOf("dm"), "messages")
  for (const r of ["settings", "accounts", "wallet"]) assert.equal(sideOf(r), "settings")
  assert.equal(sideOf("relay"), "vault")
  assert.equal(sideOf("profile", true), "search")
  assert.equal(sideOf("compose"), null)
})

test("single keys work only outside text fields", () => {
  assert.deepEqual(keyCommand({ key: "j" }), { cmd: "next" })
  assert.equal(keyCommand({ key: "j", typing: true }), null)
  assert.deepEqual(keyCommand({ key: "n" }), { cmd: "compose" })
  assert.deepEqual(keyCommand({ key: "?" }), { cmd: "help" })
})

test("the browser keeps its own shortcuts", () => {
  for (const key of ["1", "n", "f", "w"]) {
    assert.equal(keyCommand({ key, metaKey: true }), null)
    assert.equal(keyCommand({ key, ctrlKey: true }), null)
  }
  assert.equal(keyCommand({ key: "j", altKey: true }), null)
})

test("g then a letter goes to a screen; an unknown letter does nothing", () => {
  assert.deepEqual(keyCommand({ key: "g" }), { pending: "g" })
  assert.deepEqual(keyCommand({ key: "m", pending: "g" }), { cmd: "go", arg: "messages" })
  assert.deepEqual(keyCommand({ key: ",", pending: "g" }), { cmd: "go", arg: "settings" })
  assert.equal(keyCommand({ key: "x", pending: "g" }), null)
})

test("Escape closes even while typing; ⌘/Ctrl+Enter sends only while typing", () => {
  assert.deepEqual(keyCommand({ key: "Escape", typing: true }), { cmd: "close" })
  assert.deepEqual(keyCommand({ key: "Enter", metaKey: true, typing: true }), { cmd: "send" })
  assert.deepEqual(keyCommand({ key: "Enter", ctrlKey: true, typing: true }), { cmd: "send" })
  assert.equal(keyCommand({ key: "Enter", metaKey: true }), null)
})
