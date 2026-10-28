// Vault notifications while the tab is open: lines newer than the last one raised and the last look become
// notifications (three at most, then one summary), a click opens what the line is about, the title counts lines newer
// than the Vault list's seen mark, and the switch is off until the browser grants permission on the user's tap.
import test from "node:test"
import assert from "node:assert/strict"
import {
  notifyOn, setNotifyOn, turnOn, permission, readMark, writeMark, readSince, unreadFrom, vaultLines, unreadLines, titleWith, lineHref, lineNotice,
  noticesFor, lookingAtVault, whoText, MAX_AT_ONCE,
} from "../src/net/notify-watch.js"
import { writeSeen, onSeen } from "../src/net/vault-new.js"

const ME = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64), D = "d".repeat(64), E = "e".repeat(64)
const memory = () => { const m = new Map(); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) } }
const note = (id, pubkey, created_at, tags = [], content = "hi", kind = 1) => ({ id, pubkey, kind, created_at, tags, content })
const MINE = note("1".repeat(64), ME, 100, [], "my note about sourdough")
const names = { [B]: "Ann", [C]: "Bob" }
const nameOf = pk => names[pk] ?? ""

test("the switch is off until the browser grants permission, and only asks when turned on", async () => {
  const s = memory()
  assert.equal(notifyOn(s), false, "off by default")
  let asked = 0
  const Denied = Object.assign(function () {}, { permission: "default", requestPermission: async () => { asked++; return "denied" } })
  assert.equal(await turnOn(Denied, s), "denied"); assert.equal(asked, 1); assert.equal(notifyOn(s), false)
  const Granted = Object.assign(function () {}, { permission: "default", requestPermission: async () => { asked++; return "granted" } })
  assert.equal(await turnOn(Granted, s), "granted"); assert.equal(notifyOn(s), true)
  const Already = Object.assign(function () {}, { permission: "granted", requestPermission: async () => { throw new Error("must not ask again") } })
  assert.equal(await turnOn(Already, s), "granted")
  setNotifyOn(false, s); assert.equal(notifyOn(s), false)
  assert.equal(await turnOn(undefined, s), "unsupported"); assert.equal(permission(undefined), "unsupported")
})

test("the first look marks now, so old lines never pop up", () => {
  const s = memory()
  assert.equal(readMark(ME, { storage: s, now: 500 }), 500)
  assert.equal(readMark(ME, { storage: s, now: 900 }), 500)
  writeMark(ME, 600, s); assert.equal(readMark(ME, { storage: s, now: 900 }), 600)
})

test("lines are the Vault list's: likes on one note fold, newest first, own and blocked left out", () => {
  const inbound = [
    note("2".repeat(64), B, 210, [["e", MINE.id], ["p", ME]], "+", 7),
    note("3".repeat(64), C, 220, [["e", MINE.id], ["p", ME]], "🔥", 7),
    note("4".repeat(64), D, 230, [["p", ME]], "hey @you"),
    note("5".repeat(64), E, 240, [["p", ME]], "spam"),
  ]
  const lines = vaultLines({ inbound, own: [MINE], lists: [], me: ME, blocked: new Set([E]) })
  assert.deepEqual(lines.map(r => [r.kind, r.actors.length]), [["mention", 1], ["like", 2]])
  assert.equal(lines[1].created_at, 220, "a fold is as new as its newest like")
})

test("notices: newer than the mark and the last look, newest first; more than three become one summary", () => {
  const mk = (id, kind, at, extra = {}) => ({ id, kind, actors: [B], created_at: at, openId: "f".repeat(64), preview: "words", emojis: [], sats: 0, ...extra })
  const lines = [mk("x1", "reply", 300), mk("x2", "like", 250, { actors: [B, C] }), mk("x3", "zap", 150, { sats: 2100 })]
  const out = noticesFor(lines, { mark: 200, seenAt: 0, nameOf })
  assert.deepEqual(out.notices.map(n => n.title), ["Ann replied to your note"], "likes don't pop up, as on the phone by default")
  assert.equal(out.mark, 300)
  const zaps = noticesFor(lines, { mark: 100, nameOf })
  assert.deepEqual(zaps.notices.map(n => [n.title, n.body]), [["Ann replied to your note", "words"], ["⚡ New zap", "Ann zapped you 2.1k sats"]])
  assert.equal(noticesFor([mk("fut", "reply", 9_999)], { mark: 0, nameOf, now: 500 }).mark, 500, "a line dated ahead can't hold the mark there")
  assert.deepEqual(noticesFor(lines, { mark: 300, nameOf }).notices, [], "nothing twice")
  assert.equal(noticesFor(lines, { mark: 0, seenAt: 260, nameOf }).notices.length, 1, "what the user already looked at isn't raised")
  const many = Array.from({ length: MAX_AT_ONCE + 2 }, (_, i) => mk(`m${i}`, "reply", 400 + i))
  const sum = noticesFor(many, { mark: 0, nameOf, now: 1000 })
  assert.equal(sum.notices.length, 1); assert.equal(sum.notices[0].title, "5 new in your Vault"); assert.equal(sum.notices[0].href, "#/vault/activity")
  assert.equal(sum.mark, 404)
})

test("a notice's text and where its click goes", () => {
  const like = { id: "like:x", kind: "like", actors: [B, C, D], created_at: 1, openId: MINE.id, preview: "my note", emojis: ["❤️", "🔥"], sats: 0 }
  const n = lineNotice(like, nameOf)
  assert.equal(n.title, "Ann and 2 others reacted ❤️🔥"); assert.equal(n.body, "Tap to view your note"); assert.equal(n.tag, "nv:like:x")
  assert.equal(n.href, `#/thread/${MINE.id}`)
  assert.equal(lineHref({ kind: "follow", actors: [B, C], openId: null }), "#/vault/followers")
  assert.equal(lineHref({ kind: "follow", actors: [B], openId: null }), `#/profile/${B}`)
  assert.equal(lineNotice({ id: "z", kind: "zap", actors: [D], openId: null, preview: "", emojis: [], sats: 2100 }, nameOf).body, "Someone zapped you 2.1k sats")
  assert.equal(whoText([B, C], nameOf), "Ann and Bob")
  assert.equal(lineNotice({ id: "r", kind: "reply", actors: [B], openId: "f", preview: "x".repeat(300), emojis: [], sats: 0 }).body.length, 140)
  assert.equal(lineNotice({ id: "f", kind: "follow", actors: [C], openId: null }, nameOf).title, "Bob followed you")
  const npub = "npub1m2wnljjunzy50l0r2jlpzmryaj9fju6krmajkrrzclral5wymxhsen47w7"
  assert.equal(lineNotice({ id: "m", kind: "mention", actors: [B], openId: "f", preview: `hey nostr:${npub} see nostr:note1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqhq5y4g  ok` }, nameOf).body, "hey @npub1m2wnljj… see ok")
})

test("the title counts lines newer than the Vault list's seen mark, else since this browser started watching", () => {
  const lines = [{ created_at: 50 }, { created_at: 40 }, { created_at: 10 }]
  const s = memory()
  assert.equal(readSince(ME, { storage: s, now: 45 }), 45); assert.equal(readSince(ME, { storage: s, now: 99 }), 45, "set once")
  assert.equal(unreadLines(lines, unreadFrom(0, 45)).length, 1, "never opened: what came after the first watch")
  assert.equal(unreadLines(lines, unreadFrom(5, 45)).length, 3, "the Vault list's own mark wins")
  assert.equal(unreadLines(lines, 30).length, 2)
  assert.equal(titleWith(2, "Nostr Vault"), "(2) Nostr Vault"); assert.equal(titleWith(0, "Nostr Vault"), "Nostr Vault")
  assert.equal(titleWith(120, "Nostr Vault"), "(99+) Nostr Vault")
})

test("a look at the Vault list moves the title's count at once", () => {
  let heard = 0
  const off = onSeen(() => heard++)
  writeSeen(ME, { activity: 5 }, memory())
  off()
  writeSeen(ME, { activity: 6 }, memory())
  assert.equal(heard, 1)
})

test("no notification while the Vault list is on screen", () => {
  assert.equal(lookingAtVault({ visibilityState: "visible" }, "#/vault"), true)
  assert.equal(lookingAtVault({ visibilityState: "visible" }, "#/vault/activity"), true)
  assert.equal(lookingAtVault({ visibilityState: "hidden" }, "#/vault"), false)
  assert.equal(lookingAtVault({ visibilityState: "visible" }, "#/feed"), false)
  assert.equal(lookingAtVault({ visibilityState: "visible" }, "#/vault/likes"), false)
})

test("the Vault list reads what the phones read: kind 16 reposts, comments, polls; likes on the first e tag", async () => {
  const { activityRows } = await import("../src/net/vault-lists.js")
  const other = "9".repeat(64)
  const inbound = [
    note("6".repeat(64), B, 300, [["e", MINE.id], ["p", ME]], "", 16),
    note("7".repeat(64), C, 310, [["E", MINE.id], ["e", MINE.id], ["p", ME]], "nice", 1111),
    note("8".repeat(64), D, 320, [["p", ME]], "which bread?", 1068),
    note("a1".padEnd(64, "0"), B, 330, [["e", MINE.id], ["e", other], ["p", ME]], "+", 7),
  ]
  const rows = activityRows(inbound, ME, { mine: [MINE] })
  assert.deepEqual(rows.map(r => r.kind), ["like", "mention", "reply", "repost"])
  assert.equal(rows[0].openId, MINE.id, "a like is on the note its first e tag names")
})

test("the Vault list leaves out muted words, hashtags and threads, and notes from outside the network", async () => {
  const { activityRows } = await import("../src/net/vault-lists.js")
  const { muteSet } = await import("../src/net/blocks.js")
  const inbound = [
    note("b1".padEnd(64, "0"), B, 300, [["p", ME]], "buy my SCAM coin"),
    note("b2".padEnd(64, "0"), B, 301, [["p", ME], ["t", "NSFW"]], "look"),
    note("b3".padEnd(64, "0"), B, 302, [["p", ME]], "hello friend"),
    note("b4".padEnd(64, "0"), E, 303, [["p", ME]], "stranger says hi"),
    note("b5".padEnd(64, "0"), E, 304, [["e", MINE.id], ["p", ME]], "+", 7),
  ]
  const blocked = muteSet([], [["word", "scam"], ["t", "nsfw"]])
  const rows = activityRows(inbound, ME, { mine: [MINE], blocked, trusted: new Set([B]) })
  assert.deepEqual(rows.map(r => [r.kind, r.actors[0]]), [["like", E], ["mention", B]], "a stranger's like stays, their note doesn't")
  assert.equal(activityRows(inbound, ME, { mine: [MINE], blocked }).length, 3, "no network yet: nobody is outside")
})
