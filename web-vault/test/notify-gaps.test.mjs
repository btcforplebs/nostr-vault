// Web notifications vs the iPhone: per-type switches (likes and reposts off by default), message pop-ups, the
// worker path Chrome on Android needs (showNotification + notificationclick), and the Vault tab's unread count.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { TYPES, readTypes, setType, lineWanted, typeOfLine } from "../src/net/notify-prefs.js"
import { noticesFor, getVaultUnread, setVaultUnread, onVaultUnread } from "../src/net/notify-watch.js"
import { dmNotices, readDmMark, dmOnScreen, DM_BODY } from "../src/net/dm-notify.js"
import { showNotice, listenNoticeClicks } from "../src/net/notify-show.js"

const ME = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64), D = "d".repeat(64)
const memory = () => { const m = new Map(); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) } }
const nameOf = pk => ({ [B]: "Ann", [C]: "Bob" })[pk] ?? ""

test("per-type switches start as the iPhone's: likes and reposts off, the rest on; a change is kept", () => {
  const s = memory()
  assert.deepEqual(readTypes(s), { mentions: true, replies: true, dms: true, zaps: true, follows: true, reactions: false, reposts: false })
  setType("reactions", true, s); setType("zaps", false, s)
  const t = readTypes(s)
  assert.equal(t.reactions, true); assert.equal(t.zaps, false); assert.equal(t.reposts, false)
  assert.deepEqual(TYPES.map(x => x.id), ["mentions", "replies", "dms", "zaps", "follows", "reactions", "reposts"])
  assert.equal(typeOfLine("quote"), "mentions"); assert.equal(typeOfLine("article"), null)
})

test("likes and reposts pop up once switched on; a switched-off kind doesn't", () => {
  const mk = (id, kind, at) => ({ id, kind, actors: [B], created_at: at, openId: "f".repeat(64), preview: "", emojis: ["🔥"], sats: 0 })
  const lines = [mk("l", "like", 30), mk("r", "repost", 20), mk("z", "zap", 10)]
  const types = { ...readTypes(memory()), reactions: true, reposts: true, zaps: false }
  const out = noticesFor(lines, { mark: 0, nameOf, now: 100, wanted: k => lineWanted(k, types) })
  assert.deepEqual(out.notices.map(n => n.title), ["Ann reacted 🔥", "Ann reposted your note"])
  assert.equal(noticesFor(lines, { mark: 0, nameOf, now: 100, wanted: k => lineWanted(k, readTypes(memory())) }).notices.length, 1, "defaults: only the zap")
})

test("messages: new ones to the user from their network pop up, not their own, Requests, or the open conversation", () => {
  const msgs = new Map([
    ["1", { id: "1", from: B, peer: B, content: "hi  there", at: 110 }],
    ["2", { id: "2", from: ME, peer: B, content: "mine", at: 120 }],
    ["3", { id: "3", from: D, peer: D, content: "stranger", at: 130 }],
    ["4", { id: "4", from: C, peer: C, content: "x".repeat(400), at: 140 }],
    ["5", { id: "5", from: B, peer: B, content: "old", at: 90 }],
  ])
  const out = dmNotices(msgs, ME, { mark: 100, hidden: new Set([D]), nameOf, now: 1000 })
  assert.deepEqual(out.notices.map(n => [n.title, n.href]), [["Message from Bob", `#/dm/${C}`], ["Message from Ann", `#/dm/${B}`]])
  assert.equal(out.notices[1].body, "hi there"); assert.equal([...out.notices[0].body].length, DM_BODY)
  assert.equal(out.mark, 140, "the stranger's message moved the mark too")
  assert.equal(dmNotices(msgs, ME, { mark: 100, hidden: new Set([D]), onScreen: C, nameOf }).notices.length, 1, "the open conversation doesn't pop up")
  const many = new Map(Array.from({ length: 5 }, (_, i) => [`m${i}`, { id: `m${i}`, from: i % 2 ? B : C, peer: i % 2 ? B : C, content: "x", at: 200 + i }]))
  const sum = dmNotices(many, ME, { mark: 100, nameOf, now: 1000 })
  assert.equal(sum.notices.length, 1); assert.equal(sum.notices[0].title, "5 new messages"); assert.equal(sum.notices[0].body, "From Bob and 1 more")
  const s = memory()
  assert.equal(readDmMark(ME, { storage: s, now: 77 }), 77); assert.equal(readDmMark(ME, { storage: s, now: 99 }), 77)
  assert.equal(dmOnScreen({ visibilityState: "visible" }, `#/dm/${B}`), B); assert.equal(dmOnScreen({ visibilityState: "hidden" }, `#/dm/${B}`), null)
})

function fakeWorker({ answers = true } = {}) {
  const shown = [], ls = new Set()
  const sw = {
    controller: { postMessage: m => { if (m === "nv-notify-ping" && answers) queueMicrotask(() => { for (const l of ls) l({ data: { type: "nv-notify-ready" } }) }) } },
    addEventListener: (t, f) => ls.add(f), removeEventListener: (t, f) => ls.delete(f),
    getRegistration: async () => ({ showNotification: async (title, o) => shown.push({ title, ...o }) }),
    emit: data => { for (const l of ls) l({ data }) },
  }
  return { sw, shown }
}

test("shown through the worker when it opens clicks; Chrome on Android (no page Notification) through the worker too", async () => {
  const n = { title: "Ann mentioned you", body: "hi", tag: "nv:x", href: "#/thread/abc" }
  const { sw, shown } = fakeWorker()
  const N = function () { throw new Error("must not be used") }
  assert.equal(await showNotice(n, { sw, N }), "worker")
  assert.deepEqual(shown[0].data, { href: "#/thread/abc" }); assert.equal(shown[0].tag, "nv:x")
  const android = fakeWorker({ answers: false })
  const Throws = function () { throw new TypeError("Illegal constructor. Use ServiceWorkerRegistration.showNotification() instead.") }
  assert.equal(await showNotice(n, { sw: android.sw, N: Throws }), "worker", "an older worker still shows it")
  assert.equal(await showNotice(n, { sw: undefined, N: Throws }), "none")
})

test("the worker's click message opens the route in the page", () => {
  const { sw } = fakeWorker()
  const loc = globalThis.location
  globalThis.location = { hash: "#/feed" }
  const stop = listenNoticeClicks(sw)
  sw.emit({ type: "nv-open", href: "#/dm/" + B })
  assert.equal(globalThis.location.hash, "#/dm/" + B)
  sw.emit({ type: "nv-open", href: "https://evil.example/" })
  assert.equal(globalThis.location.hash, "#/dm/" + B, "only app routes")
  stop(); globalThis.location = loc
})

test("sw.js: a click focuses an open app tab and tells it where to go, or opens the app there", async () => {
  const src = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8")
  const handlers = {}, posted = [], opened = []
  let tabs = [{ url: "https://nostrvault.app/vault/#/feed", focus: async () => {}, postMessage: m => posted.push(m) }]
  const self = { addEventListener: (t, f) => { handlers[t] = f }, clients: { matchAll: async () => tabs, openWindow: async u => opened.push(u) }, registration: {} }
  new Function("self", "location", "caches", src)(self, new URL("https://nostrvault.app/vault/sw.js"), {})
  const click = async href => { let p; handlers.notificationclick({ notification: { data: { href }, close() {} }, waitUntil: x => { p = x } }); await p }
  await click("#/thread/abc")
  assert.deepEqual(posted, [{ type: "nv-open", href: "#/thread/abc" }])
  tabs = []
  await click("#/dm/" + B)
  assert.deepEqual(opened, ["https://nostrvault.app/vault/#/dm/" + B])
  let answer = null
  handlers.message({ data: "nv-notify-ping", source: { postMessage: m => { answer = m } } })
  assert.deepEqual(answer, { type: "nv-notify-ready" })
})

test("the Vault tab's dot follows the unread count", () => {
  let heard = 0
  const off = onVaultUnread(() => heard++)
  setVaultUnread(3); setVaultUnread(3); setVaultUnread(0)
  off()
  assert.equal(heard, 2); assert.equal(getVaultUnread(), 0)
})
